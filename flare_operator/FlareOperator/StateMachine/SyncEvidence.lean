/-
  StateMachine/SyncEvidence.lean — SAF-03, SC-04 / EV-04.

  "Normal promotion and Prepare activation require a completed usable copy
  associated with the current source."

  flared reports "reconstruction complete" (Prepare → Active) as a one-shot
  TCP event. When the operator misses it — the classic case is a single-shot
  activation that raced an index-leader handover: flared's activate_node got
  its OK, but the leader died before persisting it, so the new leader's map
  still says Prepare — the node sits in Prepare with a full, current copy and
  nothing re-drives it. The repair path re-derives the transition.

  The ground truth used to be LSN PROXIMITY — the slave's replication cursor
  within 5000 of the master's head — which accepts three things it should
  not: a copy that is close but unfinished, a cursor from another lineage
  that happens to be numerically near, and a master that changed while the
  numbers were sampled.

  This module decides from reconstruction-completion evidence bound to the
  source, per the reviewer's SAF-03 requirement (completion bound to master
  identity and sync generation), NOT from proximity:

  * A reconstruction must have COMPLETED in this process
    (`reconstruction_completed >= 1`). flared increments that only when its
    handler finished the dump AND its activation call returned — exactly the
    handover-lost-ack case — so it is real completion, not a cursor guess.
  * That completion must be bound to THIS master's IDENTITY: the slave's
    lineage id (`rocksdb_master_id`) equals the current master's. A copy
    reconstructed from a former master carries a different id, however close
    its cursor, and is rejected until it reconstructs from this one.
  * It must be the current SYNC GENERATION: the cursor may not be AHEAD of
    the master's head (a cursor from a former master's sequence space), and
    the source must not have changed during observation — a different Active
    master (pod identity) or a different lineage id restarts the episode, and
    activation waits until the lineage matches the new source again.

  What this deliberately does NOT use is the node's own map state. flared
  sets its local state active only when the operator's map echoes the
  activation back — precisely what is lost here — so "the node calls itself
  active" is circular and can never hold in the case the repair exists for.
  Completion + lineage is the non-circular evidence.

  Scope: this covers Prepare ACTIVATION by the repair path. Promotion
  (drain/failover successor choice) still trusts the Active designation
  itself; making that designation carry its own evidence is SAF-08. flared's
  own re-announce ("map says prepare but I am active") is a separate first
  line for a different loss; this is the operator-side second line. Pure
  code: the readings come from Main.lean, the checks are in UnitTests.lean
  and the prepare-evidence E2E suite.
-/
namespace FlareOperator.SyncEvidence

/-- What one pass could read about a Prepare slave and its master. `none`
    means "not readable", never zero. -/
structure Reading where
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
  /-- Master lineage id pinned at first reading (none when not reported). A
      later different id is a source change (the master pod re-seeded). -/
  masterId : Option String := none
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

/-- A fresh episode after a source change (new master pod). -/
def Episode.restart (e : Episode) (newMaster : String) : Episode :=
  { nodeKey := e.nodeKey, masterKey := newMaster }

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
    if ms ≥ sl && ms - sl < 5000 then " (the cursor is near the master's head, which is not by itself completion)" else ""
  | _, _ => ""

/-- Judge one Prepare node from one reading, having already confirmed the
    source is unchanged. -/
private def evidence (e : Episode) (r : Reading) : Episode × Verdict :=
  match r.slaveCompleted with
  | none => (e, .wait "reconstruction counters unreadable")
  | some 0 => (e, .wait s!"no reconstruction has completed in this process{nearNote r}")
  | some n =>
    match r.slaveMasterId, r.masterId with
    | some sm, some mm =>
      if sm != mm then
        (e, .wait s!"a reconstruction completed but the node's lineage {sm} differs from the master's {mm}: copy of another source")
      else cursor e r n
    | _, _ => cursor e r n
where
  cursor (e : Episode) (r : Reading) (n : Nat) : Episode × Verdict :=
    match r.slaveLsn, r.masterSeq with
    | some sl, some ms =>
      if sl > ms then
        (e, .wait s!"a reconstruction completed but the node's cursor {sl} is AHEAD of the master's head {ms}: cursor from another sequence space")
      else (e, .activate s!"{n} reconstruction(s) completed in this process, lineage {r.masterId.getD "n/a"} matches the master, cursor {sl} ≤ head {ms}")
    | _, _ => (e, .activate s!"{n} reconstruction(s) completed in this process, lineage {r.slaveMasterId.getD "n/a"} matches the master (backend reports no cursor)")

/-- Fold one reading into the episode (pins the master lineage on first
    sight) and judge it. A changed master pod key or a changed master lineage
    id is a source change: the episode restarts and nothing is activated
    until a reconstruction from the new source is evidenced. -/
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
      else evidence e r
    | _, _ => evidence e r

end FlareOperator.SyncEvidence
