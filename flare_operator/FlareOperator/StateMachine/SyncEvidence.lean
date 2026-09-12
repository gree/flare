/-
  StateMachine/SyncEvidence.lean — SAF-03, SC-04 / EV-04.

  "Normal promotion and Prepare activation require a completed usable copy
  associated with the current source."

  flared reports "reconstruction complete" (Prepare → Active) as a one-shot
  TCP event. When the operator misses it, the node sits in Prepare and the
  repair path re-derives the transition. The ground truth used to be LSN
  PROXIMITY — the slave's replication cursor within 5000 sequence numbers
  of the master's head — which accepts three things it should not: a copy
  that is close but not finished, a cursor from another lineage that merely
  happens to be numerically near, and a master that changed while the
  numbers were being read.

  This module decides from evidence bound to the node and the episode:

  * The node ITSELF must report active in its own node map (`stats nodes`,
    its own entry). flared sets that only after its reconstruction handler
    finished and activated, or when the operator designated it active —
    and the latter is exactly what a Prepare node has not received.
  * A reconstruction must actually have COMPLETED in this process
    (`reconstruction_completed` ≥ 1). A restarted node that boots straight
    into an old map never ran one.
  * Lineage must match when the backend reports one: the slave's
    `rocksdb_master_id` equals the master's. A different id is a copy of
    something else, however close its cursor.
  * The SOURCE must be the same for the whole episode. If the partition's
    Active master, or its lineage id, differs from what was pinned when
    the episode began, the episode restarts and — because the completion
    that made the node call itself active may belong to the old source — a
    NEW completion (counter moved past the value at the change) is
    required before activation.
  * The cursor may not be AHEAD of the master's head: a cursor from a
    former master's sequence space is meaningless here.
  * Proximity is no longer a reason to activate; it is mentioned in the
    log when the node is refused, that is all.

  Scope, stated plainly: this covers Prepare ACTIVATION by the operator's
  repair path. Promotion (drain/failover successor choice) still trusts the
  Active designation itself; making that designation carry its own evidence
  is SAF-08. flared's own re-announce ("map says prepare but I am active")
  is the first line for a lost event; this is the second. Pure code: the
  readings come from Main.lean, the checks are in UnitTests.lean and the
  prepare-evidence E2E suite.
-/
namespace FlareOperator.SyncEvidence

/-- What one pass could read about a Prepare slave and its master. `none`
    means "not readable", never zero. -/
structure Reading where
  /-- The slave's own map entry for itself says active. -/
  selfActive : Option Bool := none
  /-- The slave's reconstruction_completed counter (this process). -/
  slaveCompleted : Option Nat := none
  /-- The slave's lineage id (rocksdb backend), if reported. -/
  slaveMasterId : Option String := none
  /-- The slave's replication cursor (rocksdb_repl_last_lsn). -/
  slaveLsn : Option Nat := none
  /-- The master's lineage id, if reported. -/
  masterId : Option String := none
  /-- The master's head (rocksdb_latest_sequence_number). -/
  masterSeq : Option Nat := none
  deriving Repr, BEq

/-- One node's Prepare episode under one source. -/
structure Episode where
  nodeKey : String
  masterKey : String
  /-- Master lineage id pinned at first reading (none when not reported). -/
  masterId : Option String := none
  /-- True when this episode began because the SOURCE changed: activation
      then needs a completion newer than `completedAtReset`. -/
  needsNewCompletion : Bool := false
  /-- The slave's counter when the source change was first read. -/
  completedAtReset : Option Nat := none
  /-- Passes observed in Prepare (informational). -/
  cycles : Nat := 0
  deriving Repr, BEq

inductive Verdict where
  /-- Activate; the reason names the evidence for the log. -/
  | activate (reason : String)
  /-- Keep Prepare; the reason names what is missing. -/
  | wait (reason : String)
  /-- The source changed under the episode: restart it, activate nothing. -/
  | sourceChanged (reason : String)
  deriving Repr, BEq

/-- A fresh episode after a source change. -/
def Episode.restart (e : Episode) (newMaster : String) : Episode :=
  { nodeKey := e.nodeKey, masterKey := newMaster, needsNewCompletion := true }

/-- Bring the episodes in line with the map this pass: `current` is
    (nodeKey, masterKey) for every Slave/Prepare node whose partition has an
    Active master. A node under the same master keeps its episode; under a
    different master it restarts; a node no longer Slave/Prepare ends it. -/
def reconcileEpisodes (eps : List Episode) (current : List (String × String)) : List Episode :=
  current.map fun (nodeKey, masterKey) =>
    match eps.find? (·.nodeKey == nodeKey) with
    | some e =>
      if e.masterKey == masterKey then { e with cycles := e.cycles + 1 }
      else e.restart masterKey
    | none => { nodeKey := nodeKey, masterKey := masterKey }

private def nearNote (r : Reading) : String :=
  match r.slaveLsn, r.masterSeq with
  | some sl, some ms =>
    if ms ≥ sl && ms - sl < 5000 then " (the cursor is near the master's head, which is not completion)" else ""
  | _, _ => ""

private def evidence (e : Episode) (r : Reading) : Episode × Verdict :=
  match r.selfActive with
  | none => (e, .wait s!"the node's own node map could not be read{nearNote r}")
  | some false => (e, .wait s!"the node itself does not report active: reconstruction not finished{nearNote r}")
  | some true =>
    match r.slaveCompleted with
    | none => (e, .wait "reconstruction counters unreadable")
    | some 0 => (e, .wait s!"the node reports active but no reconstruction completed in this process (booted into an old map?){nearNote r}")
    | some n =>
      match r.slaveMasterId, r.masterId with
      | some sm, some mm =>
        if sm != mm then
          (e, .wait s!"reconstruction finished but the node's lineage {sm} differs from the master's {mm}: copy of another source")
        else cursor e r n
      | _, _ => cursor e r n
where
  cursor (e : Episode) (r : Reading) (n : Nat) : Episode × Verdict :=
    match r.slaveLsn, r.masterSeq with
    | some sl, some ms =>
      if sl > ms then
        (e, .wait s!"reconstruction finished but the node's cursor {sl} is AHEAD of the master's head {ms}: cursor from another sequence space")
      else (e, .activate s!"node reports itself active, {n} reconstruction(s) completed in this process, lineage {r.masterId.getD "n/a"} matches, cursor {sl} ≤ head {ms}")
    | _, _ => (e, .activate s!"node reports itself active, {n} reconstruction(s) completed in this process (backend reports no lineage/cursor)")

/-- Fold one reading into the episode (pins the master lineage on first
    sight, records the reset baseline) and judge it. -/
def judge (e : Episode) (currentMasterKey : String) (r : Reading) : Episode × Verdict :=
  if currentMasterKey != e.masterKey then
    (e, .sourceChanged s!"partition master changed {e.masterKey} → {currentMasterKey} during observation")
  else
    let e := match e.masterId, r.masterId with
      | none, some m => { e with masterId := some m }
      | _, _ => e
    match e.masterId, r.masterId with
    | some pinned, some now =>
      if pinned != now then
        (e, .sourceChanged s!"master lineage changed {pinned} → {now} during observation")
      else afterSource e r
    | _, _ => afterSource e r
where
  afterSource (e : Episode) (r : Reading) : Episode × Verdict :=
    if !e.needsNewCompletion then evidence e r
    else
      match e.completedAtReset, r.slaveCompleted with
      | _, none => (e, .wait "source changed earlier; reconstruction counters unreadable")
      | none, some c =>
        ({ e with completedAtReset := some c },
         .wait s!"source changed: the completion the node reports may belong to the old master; waiting for a new one (counter {c})")
      | some b, some c =>
        if c == b then (e, .wait s!"source changed: no reconstruction has completed since (counter {b}){nearNote r}")
        else evidence e r

end FlareOperator.SyncEvidence
