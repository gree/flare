/-
  The partition's AUTHORITATIVE history, kept apart from what copies report
  (docs/design-authoritative-history.md; user direction 2026-10-09: "the
  operator must track state so that this does not happen"). Pure: the
  transitions and the (de)serialisation of the persisted record. Main persists
  the store (ConfigMap `{cr}-history`, optimistic concurrency) and applies a
  transition only once its write succeeded.

  A new observation NEVER replaces the authoritative history. It changes only
  by: first-build, adoption (upgrade, guarded), promotion (intent -> commit ->
  the target's new epoch with the same binding), bulk (the recorded holder,
  same binding, advances its own epoch). Restore is not automatic.
-/

namespace FlareOperator.AuthoritativeHistory

/-- What a copy is: its pod, flared process and copy. -/
structure Binding where
  podUid : String
  bootId : String
  copyId : String
  deriving Repr, BEq, Inhabited

/-- A history: lineage and source epoch. Positions are comparable only within one. -/
structure Hist where
  masterId : String
  epoch : String
  deriving Repr, BEq, Inhabited

structure Record where
  gen : Nat
  hist : Hist
  holder : String          -- node key
  binding : Binding
  since : String
  reason : String          -- first-build / adopted / promotion / bulk
  deriving Repr, BEq, Inhabited

/-- A partition's authoritative state. `unknown` is never "first build" or "empty". -/
inductive Part where
  | known (r : Record)
  | unknown (why : String)
  deriving Repr, BEq

structure Intent where
  partition : Nat
  kind : String            -- "promotion" / "first-build"
  target : String
  binding : Binding
  fromGen : Nat            -- 0 for a first build
  fromHist : Option Hist
  mapVersionBefore : Nat
  deriving Repr, BEq, Inhabited

structure Obs where
  binding : Binding
  hist : Hist
  position : Nat           -- within `hist` only
  healthy : Bool
  empty : Bool
  seenAt : String
  deriving Repr, BEq, Inhabited

structure Store where
  clusterUid : String
  parts : List (Nat × Part) := []
  intents : List Intent := []
  obs : List (String × Obs) := []
  deriving Repr, BEq

def Store.part (s : Store) (p : Nat) : Option Part := s.parts.lookup p

def Store.setPart (s : Store) (p : Nat) (v : Part) : Store :=
  { s with parts := (s.parts.filter (·.1 != p)) ++ [(p, v)] }

/-- The history to judge promotions against: `none` when it is not known. -/
def Store.recorded (s : Store) (p : Nat) : Option Hist :=
  match s.part p with
  | some (.known r) => some r.hist
  | _ => none

def Store.intentFor (s : Store) (p : Nat) : Option Intent := s.intents.find? (·.partition == p)

-- ─── transitions ──────────────────────────────────────────────────────────

inductive Change where
  | none
  | recorded (p : Nat) (r : Record) (why : String)
  | held (p : Nat) (why : String)
  | intentDropped (p : Nat) (why : String)
  deriving Repr, BEq

/-- Begin a promotion or a first build: the intent, persisted BEFORE the map commit. -/
def beginIntent (s : Store) (i : Intent) : Store :=
  { s with intents := (s.intents.filter (·.partition != i.partition)) ++ [i] }

/-- Resolve a pending intent from the persisted map and the target's observation.
    * the commit did not happen (persisted map version not past `before`, or the
      target is not the master there): the intent is dropped;
    * it happened and the target reports a history other than the intent's
      `fromHist` WITH THE SAME BINDING: recorded as the next generation;
    * the target's binding changed: held (CRITICAL; never adopted);
    * otherwise: wait. -/
def resolveIntent (s : Store) (i : Intent) (persistedMapVersion : Nat) (targetIsMaster : Bool)
    (targetObs : Option Obs) (now : String) : Store × Change :=
  let drop := fun (why : String) =>
    ({ s with intents := s.intents.filter (·.partition != i.partition) }, Change.intentDropped i.partition why)
  if !(persistedMapVersion > i.mapVersionBefore && targetIsMaster) then
    drop s!"the map commit for {i.target} did not happen (persisted v{persistedMapVersion}, before v{i.mapVersionBefore}, master there={targetIsMaster})"
  else
    match targetObs with
    | none => (s, .none)
    | some o =>
      if o.binding != i.binding then
        (s, .held i.partition s!"{i.target} changed (pod/boot/copy {repr o.binding} != {repr i.binding}) before its new history was observed")
      else if some o.hist == i.fromHist then (s, .none)
      else
        let r : Record := { gen := i.fromGen + 1, hist := o.hist, holder := i.target, binding := o.binding,
                            since := now, reason := i.kind }
        ({ (s.setPart i.partition (.known r)) with intents := s.intents.filter (·.partition != i.partition) },
         .recorded i.partition r s!"{i.kind} of {i.target} adopted as generation {r.gen}")

/-- The recorded holder (same binding) advanced its own history (flush_all /
    truncate): the next generation. Anyone else's new history is an observation. -/
def bulk (s : Store) (p : Nat) (key : String) (o : Obs) (now : String) : Store × Change :=
  match s.part p, s.intentFor p with
  | some (.known r), none =>
    if key == r.holder && o.binding == r.binding && o.hist != r.hist then
      let r' : Record := { r with gen := r.gen + 1, hist := o.hist, since := now, reason := "bulk" }
      (s.setPart p (.known r'), .recorded p r' s!"the holder {key} advanced its own history (bulk) to generation {r'.gen}")
    else (s, .none)
  | _, _ => (s, .none)

/-- Upgrade from an operator without this record: a partition WITH a map but no
    record is adopted from its CURRENT master only if that master is Active,
    readable, and not empty while another copy holds data. -/
def adopt (s : Store) (p : Nat) (masterKey : String) (o : Obs) (masterActive otherCopyHasData : Bool)
    (now : String) : Store × Change :=
  match s.part p with
  | some (.known _) => (s, .none)
  | _ =>
    if s.intentFor p |>.isSome then (s, .none)
    else if !masterActive then (s, .held p "no Active master to adopt the history from")
    else if !o.healthy then (s, .held p s!"the master {masterKey} reports an unhealthy copy")
    else if o.empty && otherCopyHasData then
      (s, .held p s!"the master {masterKey} is EMPTY while another copy holds data: not adopted")
    else
      let r : Record := { gen := 1, hist := o.hist, holder := masterKey, binding := o.binding, since := now, reason := "adopted" }
      (s.setPart p (.known r), .recorded p r s!"adopted from the current master {masterKey} (no earlier record)")

/-- A copy whose history is not the authoritative one is REJOINING: never a
    recovery source, a master candidate or read-eligible on that history. -/
def rejoining (s : Store) (p : Nat) (o : Obs) : Bool :=
  match s.recorded p with
  | some h => o.hist != h
  | none => true

/-- May a rebuild run from `sourceKey`? Only from the authoritative history (or
    the target of a pending promotion, same binding). Never from an empty or
    other-history copy onto a surviving one. -/
def rebuildSourceAllowed (s : Store) (p : Nat) (sourceKey : String) (o : Option Obs) : Bool × String :=
  match o with
  | none => (false, s!"the source {sourceKey} was not observed")
  | some ob =>
    match s.intentFor p with
    | some i =>
      if i.target == sourceKey && ob.binding == i.binding then (true, "the target of the pending promotion")
      else (false, s!"a promotion of {i.target} is pending")
    | none =>
      match s.part p with
      | some (.known r) =>
        if ob.hist == r.hist then (true, "the authoritative history")
        else (false, s!"the source {sourceKey} holds {repr ob.hist}, not the authoritative {repr r.hist}")
      | some (.unknown why) => (false, s!"the partition's history is unknown ({why})")
      | none => (false, "the partition's history is not recorded")

/-- The store a decision may use after a write: the new one only when its
    write SUCCEEDED; otherwise the old one (the decision is not taken). -/
def afterWrite (old new : Store) (writeOk : Bool) : Store := if writeOk then new else old

-- ─── persistence format (one key=value per line; any defect = unknown) ────

private def esc (x : String) : String := x.replace " " "%20"
private def unesc (x : String) : String := x.replace "%20" " "

def serialize (s : Store) : String :=
  let parts := s.parts.map fun (p, v) => match v with
    | .known r => s!"part {p} known {r.gen} {esc r.hist.masterId} {esc r.hist.epoch} {esc r.holder} {esc r.binding.podUid} {esc r.binding.bootId} {esc r.binding.copyId} {esc r.since} {esc r.reason}"
    | .unknown w => s!"part {p} unknown {esc w}"
  let intents := s.intents.map fun i =>
    s!"intent {i.partition} {esc i.kind} {esc i.target} {esc i.binding.podUid} {esc i.binding.bootId} {esc i.binding.copyId} {i.fromGen} {esc ((i.fromHist.map (·.masterId)).getD "-")} {esc ((i.fromHist.map (·.epoch)).getD "-")} {i.mapVersionBefore}"
  let obs := s.obs.map fun (k, o) =>
    s!"obs {esc k} {esc o.binding.podUid} {esc o.binding.bootId} {esc o.binding.copyId} {esc o.hist.masterId} {esc o.hist.epoch} {o.position} {if o.healthy then 1 else 0} {if o.empty then 1 else 0} {esc o.seenAt}"
  String.intercalate "\n" ([s!"cluster {esc s.clusterUid}", "format 1"] ++ parts ++ intents ++ obs ++ ["end"])

/-- `none` = the text is not a complete, well-formed record (corrupt or
    truncated): the caller treats every partition as UNKNOWN. -/
def parse (text : String) : Option Store := Id.run do
  let lines := (text.splitOn "\n").map (·.trim) |>.filter (!·.isEmpty)
  if lines.getLast? != some "end" || !lines.contains "format 1" then return none
  let mut st : Store := { clusterUid := "" }
  for l in lines do
    match l.splitOn " " with
    | ["cluster", u] => st := { st with clusterUid := unesc u }
    | ["format", "1"] => pure ()
    | ["end"] => pure ()
    | ["part", p, "known", g, mid, ep, hk, pu, bo, co, sn, rs] =>
      match p.toNat?, g.toNat? with
      | some pn, some gn =>
        let bnd : Binding := ⟨unesc pu, unesc bo, unesc co⟩
        let rec_ : Record := { gen := gn, hist := ⟨unesc mid, unesc ep⟩, holder := unesc hk, binding := bnd, since := unesc sn, reason := unesc rs }
        st := st.setPart pn (.known rec_)
      | _, _ => return none
    | ["part", p, "unknown", w] =>
      match p.toNat? with
      | some pn => st := st.setPart pn (.unknown (unesc w))
      | none => return none
    | ["intent", p, kind, target, pu, bo, co, fg, fm, fe, mv] =>
      match p.toNat?, fg.toNat?, mv.toNat? with
      | some pn, some fgn, some mvn =>
        let fh := if fm == "-" then none else some (⟨unesc fm, unesc fe⟩ : Hist)
        let bnd : Binding := ⟨unesc pu, unesc bo, unesc co⟩
        let it : Intent := { partition := pn, kind := unesc kind, target := unesc target, binding := bnd, fromGen := fgn, fromHist := fh, mapVersionBefore := mvn }
        st := beginIntent st it
      | _, _, _ => return none
    | ["obs", k, pu, bo, co, mid, ep, pos, h, e, seen] =>
      match pos.toNat? with
      | some n =>
        let bnd : Binding := ⟨unesc pu, unesc bo, unesc co⟩
        let o : Obs := { binding := bnd, hist := ⟨unesc mid, unesc ep⟩, position := n, healthy := h == "1", empty := e == "1", seenAt := unesc seen }
        st := { st with obs := (st.obs.filter (·.1 != unesc k)) ++ [(unesc k, o)] }
      | none => return none
    | _ => return none
  return some st

/-- Load: the persisted text (or its absence / unreadability) -> the store.
    ABSENT with a node map present, UNREADABLE, CORRUPT, or of ANOTHER cluster
    = every partition unknown (never a first build). Absent with no node map =
    a first build (an empty store). -/
def load (clusterUid : String) (partitions : Nat) (persisted : Option (Option String))
    (nodeMapPresent : Bool) : Store :=
  let allUnknown := fun (why : String) =>
    ({ clusterUid := clusterUid, parts := (List.range partitions).map (fun p => (p, Part.unknown why)) } : Store)
  match persisted with
  | none => allUnknown "the history record could not be read"
  | some none =>
    if nodeMapPresent then allUnknown "no history record although the cluster has a node map"
    else { clusterUid := clusterUid }
  | some (some text) =>
    match parse text with
    | none => allUnknown "the history record is corrupt or truncated"
    | some st =>
      if st.clusterUid != clusterUid then allUnknown s!"the history record belongs to another cluster ({st.clusterUid})"
      else st

end FlareOperator.AuthoritativeHistory
