/-
  Promotion by reason (decision 2026-10-08). On a pass where a promotion is
  possible, every live non-master candidate is read and classified:

  * `eligible`  — R3 says the copy is validated for its source;
  * `lagging`   — a healthy copy of the SAME history as the partition's last
                  master (recorded by the operator while that master was
                  readable), merely behind. Never a normal promotion; only the
                  masterless refill's logged last resort (NOT LOSS-FREE) may
                  seat it after the wait;
  * `legacy`    — a flared that explicitly predates R3: allowed only when the
                  map has it Active, its pod is Ready and it is not
                  reconstructing (it carries none of the newer markers, so
                  those are the only signals);
  * `empty`     — no data at all (a partition being initialised); the existing
                  empty-master guards decide;
  * `forbidden` — being rebuilt (Prepare with a copy in flight, a merging dump
                  left part-way), copy identity records disagree, quarantined,
                  R3 history re-validation against a present master or a
                  confirmed different history. Never promoted, not even after
                  the wait;
  * `unknown`   — unreadable, incomplete, or the reason cannot be told
                  (e.g. no recorded history of the last master). Held.

  The evidence is bound to the pod UID, the flared boot id and the copy id it
  was read from; the commit re-reads them and aborts when any changed.
-/

namespace FlareOperator.PromotionEvidence

inductive Class where
  | eligible
  | lagging
  | legacy
  | empty
  | forbidden (why : String)
  | unknown (why : String)
  deriving Repr, BEq

def Class.label : Class → String
  | .eligible => "eligible"
  | .lagging => "lagging (same history)"
  | .legacy => "legacy"
  | .empty => "empty"
  | .forbidden w => s!"FORBIDDEN ({w})"
  | .unknown w => s!"unknown ({w})"

/-- What the commit may promote. `lagging` only through the last resort (the
    normal paths exclude it beforehand as unfit). -/
def Class.promotable : Class → Bool
  | .eligible | .lagging | .legacy | .empty => true
  | _ => false

/-- The parsed stats of one candidate (`none` fields = not reported).
    A field that IS reported with a value outside its domain is listed in
    `invalid` (review 2026-10-08): an END line says the reply is complete,
    not that its contents are valid, and an invalid value is never read as
    an unreported one. -/
structure Stats where
  complete : Bool := false
  eligible : Option Nat := none
  sourceState : Option String := none
  identityConsistent : Option Nat := none
  quarantined : Option Nat := none
  copyPartial : Option Nat := none
  inFlight : Option Nat := none
  parked : Option Nat := none
  switchUnresolved : Option Nat := none
  reconstruction : Option String := none
  masterId : Option String := none
  sourceEpoch : Option String := none
  rebuiltFromEpoch : Option String := none
  bootId : Option String := none
  copyId : Option String := none
  items : Option Nat := none
  /-- reported keys whose value is not valid for them -/
  invalid : List String := []
  /-- at least one key that a pre-R3 flared never reports is present -/
  newFormat : Bool := false
  deriving Repr

/-- CAPABILITY markers: keys only an R3 / copy-retention flared reports.
    History fields an older RocksDB flared already reported are NOT markers
    (review round 2: v0.1.0-rc56 reports rocksdb_master_id; rc65 also
    rocksdb_source_epoch and reconstruction_current_state) — a reply with only
    those is still the older format. -/
def newFormatKeys : List String :=
  ["repl_read_source_eligible", "repl_read_source_state", "rocksdb_copy_identity_consistent",
   "rocksdb_quarantined", "rocksdb_copy_partial", "rebuild_in_flight", "rebuild_parked",
   "rocksdb_copy_id", "rocksdb_rebuilt_from_epoch", "rocksdb_switch_unresolved"]

def parseStats (out : String) : Stats :=
  let lines := (out.splitOn "\n").map (fun l => (l.replace "\r" "").trim)
  let value := fun (k : String) => lines.findSome? fun l =>
    if l.startsWith s!"STAT {k} " then some (l.drop (s!"STAT {k} ").length)
    else if l == s!"STAT {k}" then some "" else none
  -- (parsed, reported-but-invalid)
  let flag := fun (k : String) => match value k with
    | none => ((none : Option Nat), false)
    | some v => if v == "0" then (some 0, false) else if v == "1" then (some 1, false) else (none, true)
  let nat := fun (k : String) => match value k with
    | none => ((none : Option Nat), false)
    | some v => match v.toNat? with
      | some n => (some n, false)
      | none => (none, true)
  let enum := fun (k : String) (allowed : List String) => match value k with
    | none => ((none : Option String), false)
    | some v => if allowed.contains v then (some v, false) else (none, true)
  let el := flag "repl_read_source_eligible"
  let ss := enum "repl_read_source_state" ["none", "eligible", "revalidating", "needs_rebuild"]
  let ic := flag "rocksdb_copy_identity_consistent"
  let qu := flag "rocksdb_quarantined"
  let cp := flag "rocksdb_copy_partial"
  let fl := flag "rebuild_in_flight"
  let pk := flag "rebuild_parked"
  let su := flag "rocksdb_switch_unresolved"
  let rc := enum "reconstruction_current_state" ["none", "running", "succeeded", "failed", "aborted"]
  let it := nat "curr_items"
  let named := [("repl_read_source_eligible", el.2), ("repl_read_source_state", ss.2),
    ("rocksdb_copy_identity_consistent", ic.2), ("rocksdb_quarantined", qu.2), ("rocksdb_copy_partial", cp.2),
    ("rebuild_in_flight", fl.2), ("rebuild_parked", pk.2), ("rocksdb_switch_unresolved", su.2), ("reconstruction_current_state", rc.2), ("curr_items", it.2)]
  { complete := lines.contains "END"
    eligible := el.1, sourceState := ss.1, identityConsistent := ic.1, quarantined := qu.1
    copyPartial := cp.1, inFlight := fl.1, parked := pk.1, switchUnresolved := su.1, reconstruction := rc.1
    masterId := value "rocksdb_master_id"
    sourceEpoch := value "rocksdb_source_epoch"
    rebuiltFromEpoch := (value "rocksdb_rebuilt_from_epoch").filter (!·.isEmpty)
    bootId := value "reconstruction_boot_id"
    copyId := value "rocksdb_copy_id"
    items := it.1
    invalid := named.filterMap fun (k, bad) => if bad then some k else none
    newFormat := newFormatKeys.any fun k => (value k).isSome }

/-- The history this copy holds: its rebuild evidence's epoch, else its own. -/
def Stats.copyEpoch (s : Stats) : Option String :=
  s.rebuiltFromEpoch.orElse fun _ => s.sourceEpoch

/-- An explicit pre-R3 flared: NONE of the newer keys. A reply carrying any
    of them is never downgraded to this. -/
def Stats.isLegacy (s : Stats) : Bool := !s.newFormat

/-- A backend without copy evidence (not RocksDB): R3 may be reported, but
    none of the copy-level capability keys are. -/
def Stats.noCopyEvidence (s : Stats) : Bool :=
  s.copyId.isNone && s.identityConsistent.isNone
    && s.quarantined.isNone && s.copyPartial.isNone && s.inFlight.isNone && s.parked.isNone && s.switchUnresolved.isNone

/-- A known forbidden marker, whatever the backend or format (checked before
    any compatibility rule). -/
def Stats.forbiddenMarker (s : Stats) (partitionHasMaster : Bool) : Option String :=
  if s.switchUnresolved == some 1 then some "a copy switch is unresolved (live copy not proven)"
  else if s.identityConsistent == some 0 then some "copy identity records disagree"
  else if s.quarantined == some 1 then some "the empty copy left by a quarantine"
  else if s.copyPartial == some 1 then some "a merging dump left the copy part-way"
  else if s.inFlight == some 1 then some "a copy is being rebuilt (transfer or switch in flight)"
  else if s.parked == some 1 then some "a rebuild is parked part-way (its copy was never completed)"
  else if s.reconstruction == some "running" then some "a reconstruction is running on it"
  else if s.sourceState == some "needs_rebuild" then some "R3: confirmed different history"
  else if s.sourceState == some "revalidating" && partitionHasMaster then
    some "R3: history being re-validated against the present master"
  else none

/-- What the operator knows besides the stats. -/
structure Observed where
  mapPrepare : Bool          -- the map has it in Prepare
  mapActive : Bool           -- the map has it Active
  podReady : Bool
  partitionHasMaster : Bool  -- a master is in the map for its partition now
  /-- (master_id, source epoch) of the partition's last master, recorded while
      it was readable; `none` = not known (operator restarted, never read) -/
  lastMasterHistory : Option (String × String)
  /-- it is the partition's ex-master (lastMasterOf): its copy IS the last
      master's copy -/
  isLastMasterHolder : Bool := false

def classify (reply : Option String) (o : Observed) : Class :=
  match reply with
  | none => .unknown "stats unreadable"
  | some out =>
    let s := parseStats out
    if !s.complete then .unknown "stats incomplete"
    else if !s.invalid.isEmpty then .unknown s!"invalid value(s) reported for {s.invalid}"
    else match s.forbiddenMarker o.partitionHasMaster with
    | some why => .forbidden why
    | none =>
    if s.isLegacy then
      -- no markers to trust: only the map, the pod and the reconstruction say
      if s.items == some 0 then .empty
      else if o.mapActive && !o.mapPrepare && o.podReady then .legacy
      else .unknown "a pre-R3 flared that is not Active, Ready and idle"
    else if s.noCopyEvidence then
      if s.sourceState == some "revalidating" then .unknown "re-validating with no master, and no copy evidence to tell its history"
      else if s.eligible == some 1 && o.mapActive && !o.mapPrepare then .eligible
      else if s.items == some 0 then .empty
      else if o.mapActive && !o.mapPrepare && o.podReady then .legacy
      else .unknown "a backend without copy evidence that is not Active, Ready and idle"
    else if s.sourceState == some "revalidating" then
      -- the master went while it was re-validating: its going is NOT
      -- evidence. Only a copy proven to be the RECORDED last master's
      -- history (not the unrecorded ex-master fallback) is merely lagging.
      match o.lastMasterHistory, s.masterId, s.copyEpoch with
      | some (mid, ep), some cm, some ce =>
        if cm == mid && ce == ep then .lagging
        else .unknown s!"re-validating, and its history ({cm}/{ce}) is not the recorded last master's ({mid}/{ep})"
      | _, _, _ => .unknown "re-validating when the master went, and the last master's history was not recorded"
    else if s.eligible == some 1 && o.mapActive && !o.mapPrepare then .eligible
    else if (s.items == some 0) && s.copyPartial == some 0 && s.inFlight != some 1 then .empty
    else
      match o.lastMasterHistory, s.masterId, s.copyEpoch with
      | some (mid, ep), some cm, some ce =>
        if cm == mid && ce == ep then .lagging
        else .unknown s!"its history ({cm}/{ce}) is not the last master's ({mid}/{ep})"
      | none, _, _ =>
        -- no record (e.g. the operator restarted after the master went):
        -- only the ex-master's own copy is known to be that history
        if o.isLastMasterHolder then .lagging
        else .unknown "the last master's history was not recorded"
      | _, _, _ => .unknown "the copy does not report its history"

/-- At commit the candidate is CLASSIFIED AGAIN from a fresh read: the same
    process and copy can still start a rebuild or a re-validation after the
    pass read it. The fresh class must be the one the pass decided on (an
    eligible copy that became lagging was chosen as eligible: abort). -/
def reclassifyAllows (passClass fresh : Class) : Bool × String :=
  if !fresh.promotable then (false, s!"its state changed after it was read: now {fresh.label}")
  else if fresh != passClass then (false, s!"its class changed after it was read ({passClass.label} -> {fresh.label})")
  else (true, fresh.label)

/-- The ONE explicit exception to reading a candidate before its promotion
    (review 2026-10-08): the first master of a partition that no copy has
    held — the node was a Proxy (or new) and, in the map before the pass, no
    node is a master or slave of that partition and none is its ex-master.
    `members` = (master-or-slave, partition, lastMasterOf) of every node. -/
def firstMasterOfNewPartition (wasProxyOrNew : Bool) (members : List (Bool × Int × Int)) (p : Int) : Bool :=
  wasProxyOrNew && p ≥ 0 &&
    !(members.any fun (ms, part, lm) => (ms && part == p) || lm == p)

/-- An existing copy promoted on a pass that did not read the candidates is
    read and classified AT COMMIT; only a normal promotion passes there
    (a lagging copy is seated only by the masterless last resort, which is a
    reading pass). -/
def commitTimeAllows : Class → Bool
  | .eligible | .legacy | .empty => true
  | _ => false

/-- Evidence bound to what it was read from; the commit re-reads these. -/
structure Binding where
  podUid : Option String
  bootId : Option String
  copyId : Option String
  deriving Repr, BEq

def bindingOf (podUid : Option String) (reply : Option String) : Binding :=
  let s := (reply.map parseStats).getD {}
  { podUid := podUid, bootId := s.bootId, copyId := s.copyId }

/-- At commit: promote only a candidate classified promotable on this pass
    whose pod, flared process and copy are still the ones read. -/
def commitAllows (cls : Option Class) (read now : Binding) : Bool × String :=
  match cls with
  | none => (false, "not read on this pass")
  | some c =>
    if !c.promotable then (false, c.label)
    else if read.podUid.isNone || read != now then
      (false, s!"the evidence was read from {repr read} but the candidate is now {repr now}")
    else (true, c.label)

end FlareOperator.PromotionEvidence
