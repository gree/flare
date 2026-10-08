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

/-- The parsed stats of one candidate (`none` fields = not reported). -/
structure Stats where
  complete : Bool := false
  eligible : Option Nat := none
  sourceState : Option String := none
  identityConsistent : Option Nat := none
  quarantined : Option Nat := none
  copyPartial : Option Nat := none
  inFlight : Option Nat := none
  reconstruction : Option String := none
  masterId : Option String := none
  sourceEpoch : Option String := none
  rebuiltFromEpoch : Option String := none
  bootId : Option String := none
  copyId : Option String := none
  items : Option Nat := none
  deriving Repr

def parseStats (out : String) : Stats :=
  let lines := (out.splitOn "\n").map (fun l => (l.replace "\r" "").trim)
  let value := fun (k : String) => lines.findSome? fun l =>
    if l.startsWith s!"STAT {k} " then some (l.drop (s!"STAT {k} ").length) else none
  let nat := fun (k : String) => (value k).bind String.toNat?
  { complete := lines.contains "END"
    eligible := nat "repl_read_source_eligible"
    sourceState := value "repl_read_source_state"
    identityConsistent := nat "rocksdb_copy_identity_consistent"
    quarantined := nat "rocksdb_quarantined"
    copyPartial := nat "rocksdb_copy_partial"
    inFlight := nat "rebuild_in_flight"
    reconstruction := value "reconstruction_current_state"
    masterId := value "rocksdb_master_id"
    sourceEpoch := value "rocksdb_source_epoch"
    rebuiltFromEpoch := (value "rocksdb_rebuilt_from_epoch").filter (!·.isEmpty)
    bootId := value "reconstruction_boot_id"
    copyId := value "rocksdb_copy_id"
    items := nat "curr_items" }

/-- The history this copy holds: its rebuild evidence's epoch, else its own. -/
def Stats.copyEpoch (s : Stats) : Option String :=
  s.rebuiltFromEpoch.orElse fun _ => s.sourceEpoch

/-- An explicit pre-R3 flared: none of the R3 / copy-retention keys. -/
def Stats.isLegacy (s : Stats) : Bool :=
  s.eligible.isNone && s.sourceState.isNone && s.identityConsistent.isNone && s.copyId.isNone

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
    else if s.isLegacy then
      -- no markers to trust: only the map, the pod and the reconstruction say
      if s.items == some 0 && s.reconstruction != some "running" then .empty
      else if o.mapActive && !o.mapPrepare && o.podReady && s.reconstruction != some "running" then .legacy
      else .unknown "a pre-R3 flared that is not Active, Ready and idle"
    else if s.identityConsistent == some 0 then .forbidden "copy identity records disagree"
    else if s.quarantined == some 1 then .forbidden "the empty copy left by a quarantine"
    else if s.copyPartial == some 1 then .forbidden "a merging dump left the copy part-way"
    else if s.inFlight == some 1 then .forbidden "a copy is being rebuilt (transfer or switch in flight)"
    else if s.sourceState == some "needs_rebuild" then .forbidden "R3: confirmed different history"
    else if s.sourceState == some "revalidating" && o.partitionHasMaster then
      .forbidden "R3: history being re-validated against the present master"
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
