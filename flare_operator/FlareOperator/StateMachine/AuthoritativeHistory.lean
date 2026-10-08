/-
  The partition's AUTHORITATIVE history, kept apart from what copies report
  (docs/design-authoritative-history.md; user direction 2026-10-09: "the
  operator must track state so that this does not happen"; revised after the
  review of 061cd2b / cfd36f1). Pure: transitions and the strict persisted
  format. Main persists the store (ConfigMap `{cr}-history`, under the lease)
  and applies a change only once its write succeeded.

  The record changes ONLY by:
    * first-build — in a store CREATED as a first build (before any node map);
    * adopted — an absent record with a node map, and an explicit MIGRATION
      APPROVAL for this cluster;
    * promotion — an intent (id, expected map version) persisted before the map
      commit, resolved only when the persisted map carries that id;
    * bulk — the recorded holder (same pod and boot) proves, through flared's
      persisted predecessor -> successor chain, that its copy became the new one.
  A corrupt, foreign, unreadable or HELD record is never adopted or overwritten
  automatically. A partition with no modern copy (tch, older flared) is
  UNTRACKED (the previous behaviour) only when every copy was observed
  completely; a tracked partition is never downgraded.
-/

import FlareOperator.StateMachine.PromotionEvidence

namespace FlareOperator.AuthoritativeHistory

structure Binding where
  podUid : String
  bootId : String
  copyId : String
  deriving Repr, BEq, Inhabited

structure Hist where
  masterId : String
  epoch : String
  deriving Repr, BEq, Inhabited

def reasons : List String := ["first-build", "adopted", "promotion", "bulk"]

structure Record where
  gen : Nat
  hist : Hist
  holder : String
  binding : Binding
  since : String
  reason : String
  deriving Repr, BEq, Inhabited

inductive Code where
  | absent | unreadable | corrupt | foreign | held
  deriving Repr, BEq, Inhabited

def Code.label : Code → String
  | .absent => "absent" | .unreadable => "unreadable" | .corrupt => "corrupt" | .foreign => "foreign" | .held => "held"

def Code.ofLabel : String → Option Code
  | "absent" => some .absent | "unreadable" => some .unreadable | "corrupt" => some .corrupt
  | "foreign" => some .foreign | "held" => some .held | _ => none

/-- A partition's state. A HOLD sits BESIDE the retained record (a bulk seen
    part-way, an intent that could not be completed): the record is never
    replaced by Unknown, the gates are closed while the hold stands, and the
    same transition's proof (a receipt) lifts it. -/
inductive Part where
  | known (r : Record) (hold : Option String)
  | unknown (c : Code) (why : String)
  | untracked (why : String)
  deriving Repr, BEq

def kinds : List String := ["promotion"]

structure Intent where
  id : String
  partition : Nat
  kind : String
  target : String
  binding : Binding
  fromGen : Nat
  fromHist : Hist
  expectedVersion : Nat
  deriving Repr, BEq, Inhabited

/-- One link of flared's persisted bulk chain: this copy (pred) became that
    copy (succ) with that new epoch, by a COMPLETED truncate / flush_all. -/
structure Link where
  pred : String
  succ : String
  epoch : String
  deriving Repr, BEq, Inhabited

/-- A copy as observed from ONE complete stats reply. -/
inductive Seen where
  | modern (binding : Binding) (hist : Hist) (healthy empty : Bool) (chain : List Link) (epochReason : String)
  | legacy           -- complete reply, no copy evidence (tch, older flared)
  | unreadable       -- no complete reply: NEVER read as empty or legacy
  deriving Repr, BEq

structure Store where
  clusterUid : String
  origin : String := ""          -- "first-build" when created before any node map
  parts : List (Nat × Part) := []
  intents : List Intent := []
  deriving Repr, BEq

def Store.part (s : Store) (p : Nat) : Option Part := s.parts.lookup p

def Store.setPart (s : Store) (p : Nat) (v : Part) : Store :=
  { s with parts := (s.parts.filter (·.1 != p)) ++ [(p, v)] }

def Store.recorded (s : Store) (p : Nat) : Option Hist :=
  match s.part p with
  | some (.known r _) => some r.hist
  | _ => none

def Store.held (s : Store) (p : Nat) : Option String :=
  match s.part p with
  | some (.known _ h) => h
  | some (.unknown .held w) => some w
  | _ => none

/-- Set (or lift) the hold beside the retained record. -/
def Store.setHold (s : Store) (p : Nat) (h : Option String) : Store :=
  match s.part p with
  | some (.known r _) => s.setPart p (.known r h)
  | _ => s

def Store.intentFor (s : Store) (p : Nat) : Option Intent := s.intents.find? (·.partition == p)

/-- Untracked only when explicitly decided; anything else (known, unknown,
    not yet decided) is guarded. -/
def Store.tracked (s : Store) (p : Nat) : Bool :=
  match s.part p with
  | some (.untracked _) => false
  | _ => true

inductive Change where
  | none
  | recorded (p : Nat) (r : Record) (why : String)
  | held (p : Nat) (why : String)
  | intentDropped (p : Nat) (why : String)
  | untracked (p : Nat) (why : String)
  deriving Repr, BEq

/-- Every copy of the partition observed completely (none unreadable). -/
def allObserved (copies : List (String × Seen)) : Bool :=
  !copies.isEmpty && copies.all fun (_, s) => s != .unreadable

def anyModern (copies : List (String × Seen)) : Bool :=
  copies.any fun (_, s) => match s with | .modern .. => true | _ => false

/-- Does any copy other than `k` hold data? An unreadable or legacy copy counts
    as holding data (never read as empty). -/
def othersHaveData (copies : List (String × Seen)) (k : String) : Bool :=
  copies.any fun (key, s) => key != k && match s with
    | .modern _ _ _ empty _ _ => !empty
    | .legacy => true
    | .unreadable => true

/-- First build / migration adoption / untracked, from a partition's copies.
    `approved`: the FlareCluster carries the migration approval for its uid. -/
def establish (s : Store) (p : Nat) (masterKey : Option String) (copies : List (String × Seen))
    (approved : Bool) (now : String) : Store × Change :=
  let state := s.part p
  let adoptable := match state with
    | none => s.origin == "first-build"
    | some (.unknown .absent _) => approved
    -- an approved migration whose copies were all older flared: tracked once
    -- every copy is modern (never automatically back to untracked)
    | some (.untracked _) => approved && copies.all (fun (_, x) => match x with | .modern .. => true | _ => false)
    | _ => false
  if !adoptable then (s, .none)
  else if !allObserved copies then (s, .held p "not every copy of the partition was observed completely")
  else if !anyModern copies then
    (s.setPart p (.untracked "no copy reports copy evidence (non-RocksDB backend or an older flared)"),
     .untracked p "no modern copy: untracked (previous behaviour)")
  else
    match masterKey with
    | none => (s, .held p "no master to take the history from")
    | some m =>
      match copies.lookup m with
      | some (.modern b h healthy empty _ _) =>
        if !healthy then (s, .held p s!"the master {m} reports an unhealthy copy")
        else if empty && othersHaveData copies m then (s, .held p s!"the master {m} is EMPTY while another copy holds data")
        else
          let reason := if state == none then "first-build" else "adopted"
          let r : Record := { gen := 1, hist := h, holder := m, binding := b, since := now, reason := reason }
          (s.setPart p (.known r none), .recorded p r s!"{reason} from the master {m}")
      | _ => (s, .held p s!"the master {m} is not a modern, observed copy")

/-- Follow flared's chain from `fromCopy` to `toCopy`; the epoch of the last
    link. `none` = not provable (a gap, a cycle, or a copy not reached). -/
def walkChain (chain : List Link) (fromCopy toCopy : String) : Option String := Id.run do
  let mut cur := fromCopy
  let mut ep : Option String := none
  for _ in [0:chain.length + 1] do
    if cur == toCopy then return ep
    match chain.find? (·.pred == cur) with
    | some l =>
      cur := l.succ
      ep := some l.epoch
    | none => return none
  return none

/-- The recorded holder's own COMPLETED bulk (flush_all / truncate), proven by
    flared's persisted chain from the recorded copy to the current one (several
    bulks between observations are followed link by link, never assumed). A
    copy change WITHOUT that proof (truncate bumps the copy id before its
    receipt is written; a crash between the two) keeps the record and sets a
    HOLD beside it; the receipt arriving later lifts the hold and adopts. -/
def bulk (s : Store) (p : Nat) (key : String) (seen : Seen) (now : String) : Store × Change :=
  match s.part p, s.intentFor p, seen with
  | some (.known r h), none, .modern b hs healthy _ chain epochReason =>
    if key != r.holder || b.copyId == r.binding.copyId then (s, .none)
    else if !(b.copyId.startsWith ((r.binding.copyId.splitOn ":").headD "" ++ ":")) then (s, .none)  -- another copy: not the holder's bulk
    else
      match walkChain chain r.binding.copyId b.copyId with
      | some ep =>
        if ep == hs.epoch && epochReason == "bulk" && healthy then
          let r' : Record := { r with gen := r.gen + 1, hist := hs, binding := b, since := now, reason := "bulk" }
          (s.setPart p (.known r' none), .recorded p r' s!"the holder {key} completed bulk ({r.binding.copyId} -> {b.copyId}), generation {r'.gen}{if h.isSome then " (hold lifted)" else ""}")
        else
          let why := "bulk part-way: the chain does not yet end at the copy's epoch with reason bulk, healthy"
          (s.setHold p (some why), if h == some why then .none else .held p why)
      | none =>
        let why := s!"bulk part-way: the copy changed from {r.binding.copyId} to {b.copyId} and no receipt proves it yet"
        (s.setHold p (some why), if h == some why then .none else .held p why)
  | _, _, _ => (s, .none)

/-- The holder RESTARTED normally (new process, maybe a new pod UID on the same
    volume): the SAME copy id and the SAME history, healthy = the record is
    re-bound to the new pod / boot (generation unchanged). An empty DB has a
    new copy id and never re-binds. -/
def rebind (s : Store) (p : Nat) (key : String) (seen : Seen) : Store × Change :=
  match s.part p, seen with
  | some (.known r h), .modern b hs healthy _ _ _ =>
    if key == r.holder && b.copyId == r.binding.copyId && hs == r.hist && healthy
        && (b.podUid != r.binding.podUid || b.bootId != r.binding.bootId) then
      let r' : Record := { r with binding := b }
      (s.setPart p (.known r' h), .recorded p r' s!"the holder {key} restarted with the same copy and history: re-bound")
    else (s, .none)
  | _, _ => (s, .none)

/-- Begin a promotion: refused while another intent of the partition is
    pending, or when the partition is not KNOWN. -/
def beginIntent (s : Store) (i : Intent) : Option Store :=
  match s.part i.partition, s.intentFor i.partition with
  | some (.known r none), none =>
    if i.fromGen == r.gen && i.fromHist == r.hist then some { s with intents := s.intents ++ [i] } else none
  | _, _ => none

/-- Resolve from the PERSISTED map (its version and the transition ids it
    carries) and a FRESH observation of the target. -/
def resolveIntent (s : Store) (i : Intent) (persistedVersion : Nat) (persistedIds : List String)
    (targetMasterThere : Bool) (seen : Seen) (now : String) : Store × Change :=
  let clear := fun (st : Store) => { st with intents := st.intents.filter (·.id != i.id) }
  let hold := fun (why : String) => (clear (s.setHold i.partition (some s!"{i.id}: {why}")), Change.held i.partition why)
  if !persistedIds.contains i.id then
    if persistedVersion ≥ i.expectedVersion then
      (clear s, .intentDropped i.partition s!"the persisted map v{persistedVersion} does not carry {i.id}: that commit never happened")
    else (s, .none)
  else if !targetMasterThere then hold s!"{i.target} is not the master in the map that carries the intent"
  else
    match seen with
    | .modern b h healthy _ _ _ =>
      if b != i.binding then hold s!"{i.target} changed (pod / boot / copy) before its new history was observed"
      else if !healthy then hold s!"{i.target} reports an unhealthy copy"
      else if h == i.fromHist then (s, .none)
      else if !(match s.part i.partition with | some (.known rc _) => rc.gen == i.fromGen && rc.hist == i.fromHist | _ => false) then
        hold "the record changed under the pending intent (its generation / history is not the intent's)"
      else
        let r : Record := { gen := i.fromGen + 1, hist := h, holder := i.target, binding := b, since := now, reason := "promotion" }
        (clear (s.setPart i.partition (.known r none)), .recorded i.partition r s!"{i.id} adopted as generation {r.gen}")
    | _ => (s, .none)

/-- May a rebuild copy from `sourceKey` onto the target? `source` and
    `target` are FRESH reads at the commit boundary. Only the RECORD's holder
    with its binding and history, healthy; never while an intent is pending or
    the partition is held / unknown; never from an empty source onto a target
    that holds data or cannot be read. -/
def rebuildAllowed (s : Store) (p : Nat) (sourceKey : String) (source target : Seen) : Bool × String :=
  if !s.tracked p then (true, "untracked partition (previous behaviour)")
  else if (s.intentFor p).isSome then (false, "a promotion of the partition is pending")
  else
    match s.part p with
    | some (.known _ (some hold)) => (false, s!"the partition is held: {hold}")
    | some (.known r none) =>
      match source with
      | .modern b h healthy empty _ _ =>
        -- the SAME copy as recorded (a restarted process re-binds; a new pod
        -- UID / boot alone is not a different copy); fresh history and health
        if sourceKey != r.holder || b.copyId != r.binding.copyId then (false, s!"{sourceKey} is not the recorded holder ({r.holder}) with its copy")
        else if h != r.hist then (false, s!"{sourceKey} holds another history than the record")
        else if !healthy then (false, s!"{sourceKey} reports an unhealthy copy")
        else if empty && r.reason != "bulk" && (match target with | .modern _ _ _ e _ _ => !e | _ => true) then
          -- an empty source is the authoritative state ONLY when the record is
          -- a VERIFIED bulk (flush_all / truncate proven by flared's receipt):
          -- the target must follow it to empty. Otherwise an empty copy over
          -- a target holding data is a loss, never a source.
          (false, s!"{sourceKey} is EMPTY and the target holds data (or cannot be read), and the record is not a verified bulk: no reverse rebuild")
        else (true, "the authoritative holder")
      | _ => (false, s!"{sourceKey} was not observed as a modern copy")
    | some (.unknown c w) => (false, s!"the partition's history is {c.label} ({w})")
    | _ => (false, "the partition's history is not recorded")

/-- The store a decision may use after a write: the new one only when its
    write SUCCEEDED; otherwise the old one (the decision is not taken). -/
def afterWrite (old new : Store) (writeOk : Bool) : Store := if writeOk then new else old

-- ─── strict persisted format: any defect = the whole record corrupt ───────

private def esc (x : String) : String := (x.replace "%" "%25").replace " " "%20"
private def unesc (x : String) : String := (x.replace "%20" " ").replace "%25" "%"

def serialize (s : Store) : String :=
  let parts := s.parts.map fun (p, v) => match v with
    | .known r h => s!"part {p} known {r.gen} {esc r.hist.masterId} {esc r.hist.epoch} {esc r.holder} {esc r.binding.podUid} {esc r.binding.bootId} {esc r.binding.copyId} {esc r.since} {esc r.reason} {esc (h.getD "-")}"
    | .unknown c w => s!"part {p} unknown {c.label} {esc w}"
    | .untracked w => s!"part {p} untracked {esc w}"
  let intents := s.intents.map fun i =>
    s!"intent {esc i.id} {i.partition} {esc i.kind} {esc i.target} {esc i.binding.podUid} {esc i.binding.bootId} {esc i.binding.copyId} {i.fromGen} {esc i.fromHist.masterId} {esc i.fromHist.epoch} {i.expectedVersion}"
  String.intercalate "\n" ([s!"cluster {esc s.clusterUid}", "format 2", s!"origin {if s.origin.isEmpty then "-" else s.origin}"] ++ parts ++ intents ++ ["end"])

/-- `none` = not a complete, well-formed record: duplicates (cluster, origin,
    part, intent id or partition), unknown tags, empty tokens, gen 0, unknown
    reason / kind / code, a missing end — never "last one wins". -/
def parse (text : String) : Option Store := Id.run do
  let lines := (text.splitOn "\n").map (·.trim) |>.filter (!·.isEmpty)
  if lines.getLast? != some "end" then return none
  if (lines.filter (· == "end")).length != 1 then return none
  if (lines.filter (· == "format 2")).length != 1 then return none
  let mut uid : Option String := none
  let mut origin : Option String := none
  let mut st : Store := { clusterUid := "" }
  for l in lines do
    let toks := l.splitOn " "
    if toks.any (·.isEmpty) then return none
    match toks with
    | ["cluster", u] =>
      if uid.isSome then return none
      uid := some (unesc u)
    | ["format", "2"] => pure ()
    | ["end"] => pure ()
    | ["origin", o] =>
      if origin.isSome then return none
      if o != "-" && o != "first-build" then return none
      origin := some (if o == "-" then "" else o)
    | ["part", p, "known", g, mid, ep, hk, pu, bo, co, sn, rs, hd] =>
      let some pn := p.toNat? | return none
      let some gn := g.toNat? | return none
      if gn == 0 || !reasons.contains (unesc rs) || (st.part pn).isSome then return none
      let bnd : Binding := ⟨unesc pu, unesc bo, unesc co⟩
      let rc : Record := { gen := gn, hist := ⟨unesc mid, unesc ep⟩, holder := unesc hk, binding := bnd, since := unesc sn, reason := unesc rs }
      st := st.setPart pn (.known rc (if hd == "-" then none else some (unesc hd)))
    | ["part", p, "unknown", c, w] =>
      let some pn := p.toNat? | return none
      let some code := Code.ofLabel c | return none
      if (st.part pn).isSome then return none
      st := st.setPart pn (.unknown code (unesc w))
    | ["part", p, "untracked", w] =>
      let some pn := p.toNat? | return none
      if (st.part pn).isSome then return none
      st := st.setPart pn (.untracked (unesc w))
    | ["intent", iid, p, kind, target, pu, bo, co, fg, fm, fe, ev] =>
      let some pn := p.toNat? | return none
      let some fgn := fg.toNat? | return none
      let some evn := ev.toNat? | return none
      if !kinds.contains (unesc kind) || fgn == 0 then return none
      if st.intents.any (fun i => i.id == unesc iid || i.partition == pn) then return none
      let bnd : Binding := ⟨unesc pu, unesc bo, unesc co⟩
      let it : Intent := { id := unesc iid, partition := pn, kind := unesc kind, target := unesc target, binding := bnd, fromGen := fgn, fromHist := ⟨unesc fm, unesc fe⟩, expectedVersion := evn }
      st := { st with intents := st.intents ++ [it] }
    | _ => return none
  let some u := uid | return none
  let some o := origin | return none
  return some { st with clusterUid := u, origin := o }

/-- Load. ABSENT with a node map = every partition unknown `absent` (adoptable
    only with the migration approval). UNREADABLE / CORRUPT / FOREIGN = unknown
    with that code (never adopted). ABSENT with no node map = a first build: the
    caller persists this store BEFORE the first node map. -/
def load (clusterUid : String) (partitions : Nat) (persisted : Option (Option String))
    (nodeMapPresent : Bool) : Store :=
  let allUnknown := fun (c : Code) (why : String) =>
    ({ clusterUid := clusterUid, parts := (List.range partitions).map (fun p => (p, Part.unknown c why)) } : Store)
  match persisted with
  | none => allUnknown .unreadable "the history record could not be read"
  | some none =>
    if nodeMapPresent then allUnknown .absent "no history record although the cluster has a node map"
    else { clusterUid := clusterUid, origin := "first-build" }
  | some (some text) =>
    match parse text with
    | none => allUnknown .corrupt "the history record is corrupt or truncated"
    | some st =>
      if st.clusterUid != clusterUid then allUnknown .foreign s!"the history record belongs to another cluster ({st.clusterUid})"
      else st

/-- ONE copy as seen from one stats reply (`none` = the read failed). LEGACY
    only for a complete reply with NONE of the newer keys; a reply with some
    of them but not every one needed, an invalid value, or a missing pod UID
    is UNREADABLE (Unknown); health is the classifier's own rule (any
    forbidden marker, an inconsistent identity = unhealthy). -/
def seenOfReply (podUid : String) (reply : Option String) : Seen :=
  match reply with
  | none => .unreadable
  | some out =>
    let s := PromotionEvidence.parseStats out
    if !s.complete || !s.invalid.isEmpty then .unreadable
    else if !s.newFormat then .legacy
    else
      match s.masterId, s.copyEpoch, s.bootId, s.copyId with
      | some mid, some ep, some boot, some cid =>
        if mid.isEmpty || ep.isEmpty || boot.isEmpty || cid.isEmpty || podUid.isEmpty then .unreadable else
        let healthy := s.identityConsistent == some 1 && (s.forbiddenMarker false).isNone
        let stat := fun (k : String) => ((out.splitOn "\n").findSome? fun l =>
          let t := (l.replace "\r" "").trim
          if t.startsWith s!"STAT {k} " then some (t.drop (s!"STAT {k} ").length) else none)
        let chainRaw := (stat "rocksdb_bulk_chain").getD "-"
        let chain := if chainRaw == "-" then [] else (chainRaw.splitOn ";").filterMap fun e =>
          match e.splitOn ">" with
          | [pr, rest] =>
            match rest.splitOn "@" with
            | [su, epo] => some ({ pred := pr, succ := su, epoch := epo } : Link)
            | _ => none
          | _ => none
        .modern ⟨podUid, boot, cid⟩ ⟨mid, ep⟩ healthy (s.items == some 0) chain ((stat "rocksdb_source_epoch_reason").getD "")
      | _, _, _, _ => .unreadable

/-- The transition ids a committed map carries: the last 16, and EVERY id whose
    intent is still pending (never dropped before it is resolved). -/
def keepTransitions (all pending : List String) : List String :=
  let recent := (all.reverse.take 16).reverse
  all.filter (fun t => recent.contains t || pending.contains t)

/-- Whether a pass may go on to persist a node map: a FIRST BUILD (no record,
    no node map) only once its first-build record has been written. -/
def mapMayBePersisted (persisted : Option (Option String)) (nodeMapPresent firstBuildWritten : Bool) : Bool :=
  match persisted with
  | some none => nodeMapPresent || firstBuildWritten
  | none => false
  | some (some _) => true

/-- A store loaded from a CORRUPT / FOREIGN / UNREADABLE record is never written
    back (an operator inspects and deletes it). -/
def writable (s : Store) : Bool :=
  !(s.parts.any fun (_, v) => match v with
    | .unknown .corrupt _ | .unknown .foreign _ | .unknown .unreadable _ => true
    | _ => false)

end FlareOperator.AuthoritativeHistory
