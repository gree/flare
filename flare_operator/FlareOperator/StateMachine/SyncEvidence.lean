/-
  StateMachine/SyncEvidence.lean — SAF-03, SC-04 / EV-04.

  "Normal promotion and Prepare activation require a completed usable copy
  associated with the current source."

  flared reports "reconstruction complete" (Prepare → Active) as a one-shot
  TCP event. When the operator misses it — the classic case is a single-shot
  activation that raced an index-leader handover — the node sits in Prepare
  with a full, current copy and nothing re-drives it. The repair path
  re-derives the transition.

  The judgement reads ONE COMPLETION RECORD that flared keeps per process
  (stats.h): a random per-process boot id, the id and state of the LATEST
  reconstruction handler, and the id and source of the LAST SUCCESSFUL one.
  This replaced two weaker things in turn — LSN proximity, then cumulative
  started/completed counters. The counters were wrong for two cases review
  found: a failed or aborted handler leaves started and completed unequal
  forever, so a later success could never be recognised; and a restart
  resets them to values the previous process may also have shown.

  Complete, current copy from the current source means:
  * the latest reconstruction (current_id ≥ 1) is not RUNNING;
  * it is the one that SUCCEEDED (last_success_id == current_id) — a
    failed or aborted latest handler leaves a truncated, partial store,
    whatever earlier success exists;
  * its SOURCE is the current master (last_success_source == master key),
    which binds the copy to master identity and makes a master change
    self-gating.
  * On RocksDB, additionally: lineage matches (rocksdb_master_id) and the
    cursor is seeded and sane (0 < repl_last_lsn ≤ head). A RocksDB reply
    missing those is TRUNCATED and refused; the backend is told from a
    COMPLETE master reply (END present) — any rocksdb_ key means RocksDB.
  * The source must be unchanged for the episode (master pod key and
    master lineage id pinned).

  Deliberately NOT used: the node's own map state (set only from the
  operator's echo — circular) and cursor proximity. Scope: Prepare
  ACTIVATION by the repair path; promotion still trusts the Active
  designation (SAF-08). Pure code; readings from Main.lean.
-/
namespace FlareOperator.SyncEvidence

/-- What one pass could read about a Prepare slave and its master. `none`
    means "not readable", never zero. -/
structure Reading where
  /-- flared reconstruction_boot_id: random per process. -/
  bootId : Option Nat := none
  /-- flared reconstruction_current_id: ordinal of the latest handler. -/
  currentId : Option Nat := none
  /-- flared reconstruction_current_state: none/running/succeeded/failed/aborted. -/
  currentState : Option String := none
  /-- flared reconstruction_last_success_id. -/
  lastSuccessId : Option Nat := none
  /-- flared reconstruction_last_success_source: master host:port copied from. -/
  lastSuccessSource : Option String := none
  /-- The slave's lineage id (rocksdb_master_id), if reported. -/
  slaveMasterId : Option String := none
  /-- The slave's replication cursor (rocksdb_repl_last_lsn). -/
  slaveLsn : Option Nat := none
  /-- The master's lineage id, if reported. -/
  masterId : Option String := none
  /-- The master's head (rocksdb_latest_sequence_number). -/
  masterSeq : Option Nat := none
  /-- Backend from the master's stats reply: `some true` = complete reply
      with rocksdb_ keys; `some false` = complete reply without; `none` =
      incomplete reply, nothing can be told. -/
  masterIsRocksdb : Option Bool := none
  deriving Repr, BEq

/-- One node's Prepare episode under one source. -/
structure Episode where
  nodeKey : String
  masterKey : String
  /-- Master lineage id pinned at first reading (none when not reported). -/
  masterId : Option String := none
  /-- Boot id last seen (informational: a change is a restart). -/
  bootSeen : Option Nat := none
  /-- Passes observed in Prepare (informational). -/
  cycles : Nat := 0
  deriving Repr, BEq

inductive Verdict where
  | activate (reason : String)
  | wait (reason : String)
  | sourceChanged (reason : String)
  deriving Repr, BEq

def Episode.restart (e : Episode) (newMaster : String) : Episode :=
  { nodeKey := e.nodeKey, masterKey := newMaster }

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

/-- RocksDB: lineage and a seeded, sane cursor are REQUIRED. -/
private def rocksdbEvidence (e : Episode) (r : Reading) (why : String) : Episode × Verdict :=
  match r.slaveMasterId, r.masterId, r.slaveLsn, r.masterSeq with
  | some sm, some mm, some sl, some ms =>
    if sm != mm then
      (e, .wait s!"the completed copy's lineage {sm} differs from the master's {mm}: copy of another source")
    else if sl == 0 then
      (e, .wait "the completed copy's cursor is 0: a completed RocksDB reconstruction seeds a nonzero cursor, so no complete copy of this source is present")
    else if sl > ms then
      (e, .wait s!"the completed copy's cursor {sl} is AHEAD of the master's head {ms}: cursor from another sequence space")
    else
      (e, .activate s!"{why}; lineage {mm} matches the master; cursor {sl} seeded and ≤ head {ms}")
  | _, _, _, _ =>
    (e, .wait "RocksDB backend but lineage/cursor evidence is missing from the stats reply (truncated?); refusing to activate on a partial reading")

/-- Judge from the completion record, the source already confirmed unchanged. -/
private def evidence (e : Episode) (currentMasterKey : String) (r : Reading) : Episode × Verdict :=
  let e := { e with bootSeen := r.bootId }
  match r.currentId, r.currentState, r.lastSuccessId with
  | some cid, some st, some lsid =>
    if cid == 0 then
      (e, .wait s!"no reconstruction has run in this process{nearNote r}")
    else if st == "running" then
      (e, .wait s!"reconstruction #{cid} is RUNNING: the store is being rebuilt, so any earlier completion is not the current copy")
    else if lsid != cid then
      (e, .wait s!"the latest reconstruction #{cid} did not succeed (state {st}; last success #{lsid}): the store may hold a partial copy{nearNote r}")
    else
      match r.lastSuccessSource with
      | none => (e, .wait "the successful reconstruction's source is unreadable")
      | some src =>
        if src != currentMasterKey then
          (e, .wait s!"the successful reconstruction #{cid} copied from {src}, not the current master {currentMasterKey}: copy of another source")
        else
          let why := s!"reconstruction #{cid} succeeded from the current master {src} and none is running"
          match r.masterIsRocksdb with
          | none => (e, .wait "the master's stats reply was incomplete: cannot tell the backend or read lineage/cursor")
          | some true => rocksdbEvidence e r why
          | some false => (e, .activate s!"{why} (backend reports no lineage/cursor to check)")
  | _, _, _ => (e, .wait "reconstruction record unreadable")

/-- Fold one reading into the episode (pins the master lineage on first
    sight) and judge it. A changed master pod key or master lineage id is a
    source change: the episode restarts and nothing is activated until a
    reconstruction from the new source is evidenced. -/
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
      else evidence e currentMasterKey r
    | _, _ => evidence e currentMasterKey r

end FlareOperator.SyncEvidence
