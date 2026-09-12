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

  The ground truth used to be LSN PROXIMITY, which accepts a copy that is
  close but unfinished, a cursor from another lineage that happens to be
  numerically near, and a master that changed while the numbers were read.

  This module decides from reconstruction-completion evidence bound to the
  CURRENT generation and the CURRENT source. The generation comes from two
  process-lifetime counters flared exposes: `reconstruction_started` (S,
  incremented when a reconstruction handler begins) and
  `reconstruction_completed` (C, incremented when one finishes and its
  activation call returned).

  * COMPLETE, CURRENT GENERATION: `S == C` and `C ≥ 1`. `S > C` means a
    reconstruction is IN FLIGHT — the node has truncated its store and is
    copying — and any earlier success is not the current copy; a past
    `C ≥ 1` alone proves nothing about what is on disk now. `S == C == 0` is
    a fresh process that has not reconstructed. Both counters reset on a
    process restart, so the rule is restart-safe without a baseline: it is
    a statement about THIS process.
  * BOUND TO THE MASTER'S IDENTITY (RocksDB): the slave's lineage id
    (`rocksdb_master_id`) must equal the current master's. A copy from a
    former master carries a different id and is refused until the node
    reconstructs from this one — which also makes a master change
    self-gating.
  * CURRENT SYNC GENERATION (RocksDB): the cursor must be SEEDED and SANE:
    `0 < repl_last_lsn ≤ master head`. A completed RocksDB reconstruction
    seeds the cursor from the source; zero means no complete copy exists,
    and a cursor ahead of the head belongs to another sequence space.
    Proximity is NOT a criterion; it is only mentioned in a refusal log.
  * MISSING IS NOT ABSENT. A RocksDB node that fails to report lineage or
    cursor has given a TRUNCATED reply, not a different backend, and is
    refused. The backend is told from the master's stats reply: a COMPLETE
    reply (terminated by END) that carries any `rocksdb_` key is RocksDB; a
    complete reply with none is a backend that has no lineage/cursor, and
    is accepted on completion alone; an incomplete reply decides nothing.
  * SAME SOURCE for the whole episode: a different Active master (pod
    identity) or a different master lineage id restarts the episode.

  Deliberately NOT used: the node's own map state. flared sets it active
  only when the operator's map echoes the activation back — exactly what is
  lost here — so "the node calls itself active" is circular.

  Scope: Prepare ACTIVATION by the repair path. Promotion still trusts the
  Active designation (SAF-08). Pure code: readings from Main.lean, checks in
  UnitTests.lean and the prepare-evidence E2E suite.
-/
namespace FlareOperator.SyncEvidence

/-- What one pass could read about a Prepare slave and its master. `none`
    means "not readable", never zero. -/
structure Reading where
  /-- flared reconstruction_started (this process). -/
  slaveStarted : Option Nat := none
  /-- flared reconstruction_completed (this process). -/
  slaveCompleted : Option Nat := none
  /-- The slave's lineage id (rocksdb_master_id), if reported. -/
  slaveMasterId : Option String := none
  /-- The slave's replication cursor (rocksdb_repl_last_lsn). -/
  slaveLsn : Option Nat := none
  /-- The master's lineage id, if reported. -/
  masterId : Option String := none
  /-- The master's head (rocksdb_latest_sequence_number). -/
  masterSeq : Option Nat := none
  /-- Backend classification from the master's stats reply: `some true` =
      a complete reply carrying rocksdb_ keys; `some false` = a complete
      reply with none (no lineage/cursor to require); `none` = the reply was
      incomplete, so nothing can be told. -/
  masterIsRocksdb : Option Bool := none
  deriving Repr, BEq

/-- One node's Prepare episode under one source. -/
structure Episode where
  nodeKey : String
  masterKey : String
  /-- Master lineage id pinned at first reading (none when not reported). -/
  masterId : Option String := none
  /-- Highest reconstruction_started seen; a drop below it is a process
      restart (informational — the rule itself is restart-safe). -/
  startedSeen : Option Nat := none
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
private def rocksdbEvidence (e : Episode) (r : Reading) (c : Nat) : Episode × Verdict :=
  match r.slaveMasterId, r.masterId, r.slaveLsn, r.masterSeq with
  | some sm, some mm, some sl, some ms =>
    if sm != mm then
      (e, .wait s!"a reconstruction completed but the node's lineage {sm} differs from the master's {mm}: copy of another source")
    else if sl == 0 then
      (e, .wait "a reconstruction completed but the node's cursor is 0: a completed RocksDB reconstruction seeds a nonzero cursor, so no complete copy of this source is present")
    else if sl > ms then
      (e, .wait s!"a reconstruction completed but the node's cursor {sl} is AHEAD of the master's head {ms}: cursor from another sequence space")
    else
      (e, .activate s!"{c} reconstruction(s) completed in this process and none in flight; lineage {mm} matches the master; cursor {sl} seeded and ≤ head {ms}")
  | _, _, _, _ =>
    (e, .wait "RocksDB backend but lineage/cursor evidence is missing from the stats reply (truncated?); refusing to activate on a partial reading")

/-- Judge from the generation counters, having confirmed the source is
    unchanged. -/
private def evidence (e : Episode) (r : Reading) : Episode × Verdict :=
  match r.slaveStarted, r.slaveCompleted with
  | some s, some c =>
    -- Track the generation (restart detection is informational).
    let e := { e with startedSeen := some (match e.startedSeen with
      | some prev => if s ≥ prev then s else s   -- a drop is a restart; follow it
      | none => s) }
    if c == 0 then
      (e, .wait s!"no reconstruction has completed in this process (started {s}){nearNote r}")
    else if s != c then
      (e, .wait s!"a reconstruction is IN FLIGHT (started {s}, completed {c}): the store is being rebuilt, so any earlier completion is not the current copy")
    else
      match r.masterIsRocksdb with
      | none => (e, .wait "the master's stats reply was incomplete: cannot tell the backend or read lineage/cursor")
      | some true => rocksdbEvidence e r c
      | some false =>
        (e, .activate s!"{c} reconstruction(s) completed in this process and none in flight (backend reports no lineage/cursor to check)")
  | _, _ => (e, .wait "reconstruction counters unreadable")

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
      else evidence e r
    | _, _ => evidence e r

end FlareOperator.SyncEvidence
