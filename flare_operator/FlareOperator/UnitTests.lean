/-
  UnitTests.lean — executable checks for the pure decision code.

  `lake build flare_unit && .lake/build/bin/flare_unit` runs them; a non-zero
  exit means a failure, and the register records the run like any other
  check (CHECK-03b). These are not proofs and not end-to-end evidence: they
  pin the decisions of StateMachine/ReplicaRepair.lean on the cases the
  E2E harness cannot stage deterministically — a master whose counter reset,
  a destination that resolves to nothing or to a master, a request held by
  a gate and released later, a completion that must not be accepted on a
  re-announced Active alone.

  Kept as many small definitions on purpose: one large `do` block of checks
  made the elaborator crawl.
-/
import Lean.Data.Json
import FlareOperator.StateMachine.ReplicaRepair
import FlareOperator.StateMachine.SyncEvidence
import FlareOperator.StateMachine.StatsObservation

open FlareOperator.K8s
open FlareOperator.ReplicaRepair

namespace FlareOperator.UnitTests

structure Ctx where
  failures : IO.Ref (List String)
  count : IO.Ref Nat

def check (ctx : Ctx) (name : String) (ok : Bool) : IO Unit := do
  ctx.count.modify (· + 1)
  if ok then IO.println s!"ok - {name}"
  else
    IO.println s!"not ok - {name}"
    ctx.failures.modify (· ++ [name])

def node (role : FlareRole) (state : FlareState) (partition : Int) (name : String) : FlareNode :=
  { serverName := name, serverPort := 12121, role := role, state := state, partition := partition }

def slaveKey : String := "n1.svc:12121"
def masterKey : String := "n0.svc:12121"

def state : FlareClusterState :=
  { nodeMap := [(masterKey, node .Master .Active 0 "n0.svc"), (slaveKey, node .Slave .Active 0 "n1.svc")],
    nodeMapVersion := 10 }

def promoted : FlareClusterState :=
  { nodeMap := [(masterKey, node .Slave .Active 0 "n0.svc"), (slaveKey, node .Master .Active 0 "n1.svc")],
    nodeMapVersion := 10 }

def empty : Ledger := {}

/-- Ledger after the first (baseline) observation of 7 drops to the slave. -/
def l1 : Ledger := (observe empty masterKey [(slaveKey, 7)]).1

def drops (l : Ledger) (m : String) (obs : List (String × Nat)) : List (String × Nat) :=
  (observe l m obs).2

def checkObserve (ctx : Ctx) : IO Unit := do
  check ctx "first observation is a baseline, attributes nothing"
    (drops empty masterKey [(slaveKey, 7)] == [] && l1.initialized == true)
  check ctx "an increase attributes the delta"
    (drops l1 masterKey [(slaveKey, 10)] == [(slaveKey, 3)])
  check ctx "unchanged attributes nothing"
    (drops l1 masterKey [(slaveKey, 7)] == [])
  check ctx "a counter that went DOWN is a reset: the new count is all new drops"
    (drops l1 masterKey [(slaveKey, 2)] == [(slaveKey, 2)])
  check ctx "a reset to zero (fresh master, no drops yet) attributes nothing"
    (drops l1 masterKey [(slaveKey, 0)] == [])
  check ctx "a destination first seen on an INITIALIZED ledger counts fully"
    (drops l1 masterKey [("n2.svc:12121", 4)] == [("n2.svc:12121", 4)])
  check ctx "counters are keyed per master: another master's first sighting also counts"
    (drops l1 "other:12121" [(slaveKey, 1)] == [(slaveKey, 1)])

/-- One request for the slave, 3 drops. -/
def l2 : Ledger := request l1 masterKey slaveKey 3

def firstPhase (l : Ledger) : Option Phase := l.entries.head?.map (·.phase)
def firstDrops (l : Ledger) : Option Nat := l.entries.head?.map (·.drops)
def firstNodeKey (l : Ledger) : Option String := l.entries.head?.bind (·.nodeKey)
def firstHold (l : Ledger) : Option String := l.entries.head?.bind (·.hold)
def firstCurrentIdAtReseat (l : Ledger) : Option Nat := l.entries.head?.bind (·.currentIdAtReseat)

def checkRequestResolve (ctx : Ctx) : IO Unit := do
  check ctx "a request is recorded once per destination"
    (l2.entries.length == 1 && firstPhase l2 == some .requested)
  let l2b := request l2 masterKey slaveKey 2
  check ctx "more drops on the same destination extend the entry, not duplicate it"
    (l2b.entries.length == 1 && firstDrops l2b == some 5)
  let (l3, voided) := resolve l2 state
  check ctx "a destination matching a Slave resolves to its key"
    (voided.isEmpty && firstNodeKey l3 == some slaveKey)
  let (l3u, voidedU) := resolve (request l1 masterKey "ghost.svc:12121" 1) state
  check ctx "an unmatched destination stays requested and unresolved"
    (voidedU.isEmpty && l3u.entries.length == 1 && firstNodeKey l3u == none)
  let (l3v, voidedV) := resolve l2 promoted
  check ctx "a destination that is now a MASTER is voided, not demoted"
    (voidedV.length == 1 && l3v.entries.isEmpty)
  check ctx "resolution accepts the bare host as well as host:port"
    ((resolveKey state "n1.svc").map (·.1) == some slaveKey)

/-- Resolved request. -/
def l3 : Ledger := (resolve l2 state).1
/-- Held by a closed gate. -/
def lHeld : Ledger := (plan l3 false "breaker held").1
/-- Gate opened: the action list and the cleared ledger. -/
def opened : Ledger × List (String × Entry) := plan lHeld true ""
/-- Demoted at version 11. -/
def lDem : Ledger := markDemoted opened.1 slaveKey 11

def checkGate (ctx : Ctx) : IO Unit := do
  check ctx "a gated request is HELD with its reason and produces no action"
    ((plan l3 false "breaker held").2.isEmpty && firstHold lHeld == some "breaker held")
  check ctx "a held request is not excluded from assignment (only a demoted one is)"
    (heldKeys lHeld == [])
  check ctx "when the gate opens the held request becomes an action and the hold clears"
    (opened.2.map (·.1) == [slaveKey] && firstHold opened.1 == none)
  check ctx "a demoted node is held out of assignment"
    (heldKeys lDem == [slaveKey] && firstPhase lDem == some (.demoted 11))
  check ctx "plan does not act twice on a demoted entry"
    ((plan lDem true "").2.isEmpty)

/-- An observation carrying flared's completion record. -/
def obs (v : Option Nat) (boot cid : Option Nat) (st : Option String) (lsid : Option Nat)
    (src master : Option String) (m : Option (FlareRole × FlareState)) : Observation :=
  { reportedVersion := v, bootId := boot, currentId := cid, currentState := st,
    lastSuccessId := lsid, lastSuccessSource := src, currentMaster := master, mapped := m }

def stepsOf (l : Ledger) (o : Observation) : List Step :=
  (advance l [(slaveKey, o)]).2.map (·.2)

/-- Released after confirming version 11; at that moment flared was in
    process boot 100 with reconstruction #1 (its boot one) succeeded from the
    master, and 3 drops were attributed. -/
def relObs : Observation := obs (some 11) (some 100) (some 1) (some "succeeded") (some 1) (some masterKey) (some masterKey) (some (.Proxy, .Active))
def lRel : Ledger := (advance lDem [(slaveKey, relObs)]).1

def checkAdvanceHold (ctx : Ctx) : IO Unit := do
  let old := obs (some 10) (some 100) (some 1) (some "succeeded") (some 1) (some masterKey) (some masterKey) (some (.Proxy, .Active))
  check ctx "a node still reporting the OLD version stays held"
    (stepsOf lDem old == [] && heldKeys (advance lDem [(slaveKey, old)]).1 == [slaveKey])
  check ctx "a node reporting the demotion version is released, recording boot id, current id and drops at reseat"
    (stepsOf lDem relObs == [.released] && heldKeys lRel == []
      && firstPhase lRel == some .reseated
      && (lRel.entries.head?.bind (·.bootIdAtReseat)) == some 100
      && (lRel.entries.head?.bind (·.currentIdAtReseat)) == some 1
      && (lRel.entries.head?.map (·.dropsAtReseat)) == some 3)
  let unread := obs none none none none none none none (some (.Proxy, .Active))
  check ctx "unreadable stats change nothing (fail closed: stay held)"
    (stepsOf lDem unread == [] && heldKeys (advance lDem [(slaveKey, unread)]).1 == [slaveKey])

/-- Same process (boot 100), reconstruction #2 succeeded from the master. -/
def doneObs : Observation := obs (some 12) (some 100) (some 2) (some "succeeded") (some 2) (some masterKey) (some masterKey) (some (.Slave, .Active))

def checkAdvanceComplete (ctx : Ctx) : IO Unit := do
  check ctx "Slave/Prepare is in progress, not complete"
    (stepsOf lRel (obs (some 12) (some 100) (some 2) (some "running") (some 1) (some masterKey) (some masterKey) (some (.Slave, .Prepare))) == [])
  check ctx "Slave/Active with NO reconstruction newer than the reseat one (same boot, same id) is NOT completion (re-announced Active)"
    (stepsOf lRel (obs (some 12) (some 100) (some 1) (some "succeeded") (some 1) (some masterKey) (some masterKey) (some (.Slave, .Active))) == [])
  check ctx "a newer reconstruction still RUNNING is not completion"
    (stepsOf lRel (obs (some 12) (some 100) (some 2) (some "running") (some 1) (some masterKey) (some masterKey) (some (.Slave, .Active))) == [])
  check ctx "a newer reconstruction that FAILED is not completion (last success is still #1)"
    (stepsOf lRel (obs (some 12) (some 100) (some 2) (some "failed") (some 1) (some masterKey) (some masterKey) (some (.Slave, .Active))) == [])
  check ctx "a newer success from a DIFFERENT source than the current master is not completion"
    (stepsOf lRel (obs (some 12) (some 100) (some 2) (some "succeeded") (some 2) (some "old-master:12121") (some masterKey) (some (.Slave, .Active))) == [])
  check ctx "a newer reconstruction that SUCCEEDED from the current master completes and removes the entry"
    (stepsOf lRel doneObs == [.completed] && (advance lRel [(slaveKey, doneObs)]).1.entries.isEmpty)
  -- Review item 3 (second round): failed then succeeded — #2 failed, #3 succeeded.
  check ctx "failure then success: #3 succeeded after #2 failed → completion (cumulative counters would never match)"
    (stepsOf lRel (obs (some 12) (some 100) (some 3) (some "succeeded") (some 3) (some masterKey) (some masterKey) (some (.Slave, .Active))) == [.completed])
  -- Review item 4: restart whose counters equal the reseat baseline exactly.
  check ctx "restart with IDENTICAL counters (new boot 200, #1 succeeded == baseline #1) completes: the boot id tells the processes apart"
    (stepsOf lRel (obs (some 12) (some 200) (some 1) (some "succeeded") (some 1) (some masterKey) (some masterKey) (some (.Slave, .Active))) == [.completed])
  check ctx "restart whose boot reconstruction is still running is not completion"
    (stepsOf lRel (obs (some 12) (some 200) (some 1) (some "running") (some 0) (some masterKey) (some masterKey) (some (.Slave, .Active))) == [])
  -- Late drops after the reseat are requeued as exactly the increment.
  let lLate := request lRel masterKey slaveKey 2     -- 3 → 5 while reseated
  let (lReq, stLate) := advance lLate [(slaveKey, doneObs)]
  check ctx "late drops after the reseat: completion requeues exactly the increment as a fresh request"
    (stLate.map (·.2) == [.completedRequeued] && firstPhase lReq == some .requested
      && firstDrops lReq == some 2 && (lReq.entries.head?.bind (·.currentIdAtReseat)) == none
      && firstNodeKey lReq == some slaveKey)
  check ctx "a node that became MASTER while reseated is voided"
    (stepsOf lRel (obs (some 12) (some 100) (some 2) (some "succeeded") (some 2) (some masterKey) (some masterKey) (some (.Master, .Active))) == [.voided])
  let lNoBase : Ledger := { lRel with entries := lRel.entries.map fun e => { e with bootIdAtReseat := none, currentIdAtReseat := none } }
  let (lNB, stNB) := advance lNoBase [(slaveKey, doneObs)]
  check ctx "with no baseline the first readable record becomes the baseline; nothing completes yet"
    (stNB.isEmpty && (lNB.entries.head?.bind (·.currentIdAtReseat)) == some 2)

def lFull : Ledger :=
  let l := markDemoted (request l1 masterKey slaveKey 3) slaveKey 11
  { l with entries := l.entries.map fun e => { e with nodeKey := some slaveKey, hold := some "x" } }

def checkJson (ctx : Ctx) : IO Unit := do
  check ctx "ledger survives a JSON round trip"
    (Ledger.fromJson? lFull.toJson == some lFull)
  check ctx "an empty ledger round-trips"
    (Ledger.fromJson? empty.toJson == some empty)
  -- Review item 2 (second round): a PARTIALLY corrupt ledger must fail as a
  -- whole, never load as a smaller valid ledger that silently lost a request.
  let good := Lean.Json.mkObj [("dest", Lean.Json.str slaveKey), ("masterKey", Lean.Json.str masterKey),
                               ("phase", Lean.Json.mkObj [("kind", Lean.Json.str "requested")]), ("drops", Lean.Json.num 3)]
  let noMaster := Lean.Json.mkObj [("dest", Lean.Json.str "x:12121"),
                                   ("phase", Lean.Json.mkObj [("kind", Lean.Json.str "requested")]), ("drops", Lean.Json.num 1)]
  let mk := fun (entries : List Lean.Json) (counters : List Lean.Json) =>
    Lean.Json.mkObj [("initialized", Lean.Json.bool true), ("counters", Lean.Json.arr counters.toArray),
                     ("entries", Lean.Json.arr entries.toArray)]
  check ctx "strict parse: a valid entry loads"
    ((Ledger.fromJson? (mk [good] [])).map (·.entries.length) == some 1)
  check ctx "strict parse: an entry missing masterKey fails the WHOLE ledger (not an empty ledger)"
    (Ledger.fromJson? (mk [noMaster] []) == none)
  check ctx "strict parse: one valid + one invalid entry fails the whole ledger"
    (Ledger.fromJson? (mk [good, noMaster] []) == none)
  check ctx "strict parse: a malformed counter fails the whole ledger"
    (Ledger.fromJson? (mk [good] [Lean.Json.mkObj [("key", Lean.Json.str "m|d")]]) == none)
  check ctx "strict parse: an unknown phase kind fails the whole ledger"
    (Ledger.fromJson? (mk [Lean.Json.mkObj [("dest", Lean.Json.str "y:1"), ("masterKey", Lean.Json.str "m"), ("phase", Lean.Json.mkObj [("kind", Lean.Json.str "bogus")])]] []) == none)

-- ── SyncEvidence (SAF-03) ────────────────────────────────────────────

open FlareOperator.SyncEvidence in
def ep : Episode := { nodeKey := slaveKey, masterKey := masterKey }

open FlareOperator.SyncEvidence in
def rd (boot cid : Option Nat) (st : Option String) (lsid : Option Nat) (src : Option String)
    (sId mId : Option String) (sLsn mSeq : Option Nat) (rocks : Option Bool) : Reading :=
  { bootId := boot, currentId := cid, currentState := st, lastSuccessId := lsid, lastSuccessSource := src,
    slaveMasterId := sId, masterId := mId, slaveLsn := sLsn, masterSeq := mSeq, masterIsRocksdb := rocks }

-- A good RocksDB record: #1 succeeded from the master, lineage A, cursor seeded.
open FlareOperator.SyncEvidence in
def goodR : Reading := rd (some 100) (some 1) (some "succeeded") (some 1) (some masterKey) (some "A") (some "A") (some 990) (some 1000) (some true)

open FlareOperator.SyncEvidence in
def isActivate : Verdict → Bool | .activate _ => true | _ => false
open FlareOperator.SyncEvidence in
def isWait : Verdict → Bool | .wait _ => true | _ => false
open FlareOperator.SyncEvidence in
def isSourceChanged : Verdict → Bool | .sourceChanged _ => true | _ => false

open FlareOperator.SyncEvidence in
def checkEpisodes (ctx : Ctx) : IO Unit := do
  let e1 := reconcileEpisodes [] [(slaveKey, masterKey)]
  check ctx "a Slave/Prepare node under an Active master starts an episode"
    (e1.map (·.nodeKey) == [slaveKey] && e1.map (·.cycles) == [0])
  let e2 := reconcileEpisodes e1 [(slaveKey, masterKey)]
  check ctx "the same source keeps the episode and counts the pass"
    (e2.map (·.cycles) == [1])
  let e3 := reconcileEpisodes e2 [(slaveKey, "other:12121")]
  check ctx "a different master between passes restarts the episode"
    (e3.map (·.masterKey) == ["other:12121"] && e3.map (·.cycles) == [0] && e3.map (·.masterId) == [none])
  check ctx "a node no longer Slave/Prepare ends its episode"
    ((reconcileEpisodes e2 []).isEmpty)

open FlareOperator.SyncEvidence in
def checkJudgeRefusals (ctx : Ctx) : IO Unit := do
  check ctx "a changed master key is a source change, not a wait"
    (isSourceChanged (judge ep "other:12121" goodR).2)
  let (pinned, _) := judge ep masterKey goodR
  check ctx "the master lineage is pinned at first sight"
    (pinned.masterId == some "A")
  check ctx "a changed master lineage is a source change"
    (isSourceChanged (judge pinned masterKey { goodR with slaveMasterId := some "B", masterId := some "B" }).2)
  check ctx "an unreadable record is refused"
    (isWait (judge ep masterKey { goodR with currentId := none }).2)
  check ctx "no reconstruction in this process (#0) is refused even with a near cursor"
    (isWait (judge ep masterKey { goodR with currentId := some 0, lastSuccessId := some 0, currentState := some "none", slaveLsn := some 999 }).2)
  check ctx "the latest reconstruction RUNNING is refused (past success is not the current copy)"
    (isWait (judge ep masterKey { goodR with currentId := some 2, currentState := some "running", lastSuccessId := some 1 }).2)
  check ctx "the latest reconstruction FAILED after an earlier success is refused (store may be partial)"
    (isWait (judge ep masterKey { goodR with currentId := some 2, currentState := some "failed", lastSuccessId := some 1 }).2)
  check ctx "the latest reconstruction ABORTED is refused"
    (isWait (judge ep masterKey { goodR with currentId := some 2, currentState := some "aborted", lastSuccessId := some 1 }).2)
  check ctx "a success from a DIFFERENT source than the current master is refused"
    (isWait (judge ep masterKey { goodR with lastSuccessSource := some "former:12121" }).2)
  check ctx "reviewer input (round 1): same lineage, slave LSN 0, master 10000 → refused (cursor not seeded)"
    (isWait (judge ep masterKey { goodR with slaveLsn := some 0, masterSeq := some 10000 }).2)
  check ctx "a lineage mismatch is refused"
    (isWait (judge ep masterKey { goodR with slaveMasterId := some "Z" }).2)
  check ctx "a cursor AHEAD of the head is refused"
    (isWait (judge ep masterKey { goodR with slaveLsn := some 1001 }).2)
  check ctx "RocksDB with lineage missing → refused (truncated reply)"
    (isWait (judge ep masterKey { goodR with slaveMasterId := none, masterId := none }).2)
  check ctx "RocksDB with cursor missing → refused"
    (isWait (judge ep masterKey { goodR with slaveLsn := none, masterSeq := none }).2)
  check ctx "an INCOMPLETE master stats reply (backend unknown) is refused"
    (isWait (judge ep masterKey { goodR with masterIsRocksdb := none }).2)

open FlareOperator.SyncEvidence in
def checkJudgeAcceptance (ctx : Ctx) : IO Unit := do
  check ctx "RocksDB: latest #1 succeeded from the current master, lineage matches, cursor seeded → activate"
    (isActivate (judge ep masterKey goodR).2)
  check ctx "a FAR-behind but seeded cursor does not block (proximity is not the test)"
    (isActivate (judge ep masterKey { goodR with slaveLsn := some 10, masterSeq := some 1000000 }).2)
  check ctx "non-RocksDB backend (complete reply, no rocksdb keys) activates on the record alone"
    (isActivate (judge ep masterKey (rd (some 100) (some 1) (some "succeeded") (some 1) (some masterKey) none none none none (some false))).2)
  -- Review item 3 (second round): "failure then success" — #1 failed, #2 succeeded.
  check ctx "failure then success: #2 succeeded after #1 failed → activate (counters 2/1 would have said IN FLIGHT)"
    (isActivate (judge ep masterKey { goodR with currentId := some 2, lastSuccessId := some 2 }).2)
  check ctx "abort then success: #2 succeeded after #1 was aborted → activate"
    (isActivate (judge ep masterKey { goodR with currentId := some 2, lastSuccessId := some 2, currentState := some "succeeded" }).2)
  check ctx "after a restart, the new process's own #1 success activates"
    (isActivate (judge ep masterKey { goodR with bootId := some 200 }).2)
  let (afterChange, v1) := judge (ep.restart masterKey) masterKey { goodR with lastSuccessSource := some "old:12121", slaveMasterId := some "OLD", masterId := some "NEW" }
  check ctx "after a source change a success from the OLD master is refused"
    (isWait v1)
  check ctx "once a success from the new master (matching lineage) is recorded it activates"
    (isActivate (judge afterChange masterKey { goodR with currentId := some 2, lastSuccessId := some 2, slaveMasterId := some "NEW", masterId := some "NEW" }).2)

-- ── StatsObservation (SAF-04 / SAF-06) ───────────────────────────────

open FlareOperator.StatsObservation in
def isAct : EmptyMasterVerdict → Bool | .act => true | _ => false
open FlareOperator.StatsObservation in
def isSkip : EmptyMasterVerdict → Bool | .skip _ => true | _ => false

open FlareOperator.StatsObservation in
def checkStatsObservation (ctx : Ctx) : IO Unit := do
  -- parse
  check ctx "a well-formed curr_items line parses to known"
    (parseCurrItems "STAT curr_items 42\r\nEND" == Items.known 42)
  check ctx "a blank reply (dropped/reset connection) is unknown, not known 0"
    (parseCurrItems "" == Items.unknown)
  check ctx "a reply that omits curr_items is unknown"
    (parseCurrItems "STAT cmd_get 5\r\nEND" == Items.unknown)
  check ctx "a non-numeric curr_items is unknown"
    (parseCurrItems "STAT curr_items nan" == Items.unknown)
  check ctx "a genuine zero is known 0, distinct from unknown"
    (parseCurrItems "STAT curr_items 0" == Items.known 0 && Items.known 0 != Items.unknown)
  -- verdict
  check ctx "known-0 master with a known data-bearing slave → act"
    (isAct (emptyMasterVerdict (Items.known 0) (Items.known 15)))
  check ctx "a nonzero master is never empty"
    (isSkip (emptyMasterVerdict (Items.known 3) (Items.known 15)))
  check ctx "an UNKNOWN master is never treated as empty (the SAF-04 defect)"
    (isSkip (emptyMasterVerdict Items.unknown (Items.known 15)))
  check ctx "a known-0 master with an UNKNOWN slave does not delete (no confirmed successor)"
    (isSkip (emptyMasterVerdict (Items.known 0) Items.unknown))
  check ctx "both empty → skip (nothing to hand over)"
    (isSkip (emptyMasterVerdict (Items.known 0) (Items.known 0)))
  -- successor revalidation over the live map
  let mk := masterKey
  let sk := slaveKey
  check ctx "successor still valid when it is a data-bearing Active slave in the master's partition"
    (successorStillValid state mk sk [sk])
  check ctx "successor INVALID when it is not in the data-bearing set (a resync just demoted its data)"
    (successorStillValid state mk sk [] == false)
  let demotedState : FlareClusterState :=
    { state with nodeMap := [(mk, node .Master .Active 0 "n0.svc"), (sk, node .Proxy .Active (-1) "n1.svc")] }
  check ctx "successor INVALID when it was demoted to Proxy in the same tick"
    (successorStillValid demotedState mk sk [sk] == false)
  let noMaster : FlareClusterState :=
    { state with nodeMap := [(mk, node .Slave .Active 0 "n0.svc"), (sk, node .Slave .Active 0 "n1.svc")] }
  check ctx "successor INVALID when the target is no longer an Active master (leadership lost)"
    (successorStillValid noMaster mk sk [sk] == false)

def okB : Except String Unit → Bool | .ok _ => true | .error _ => false

open FlareOperator.StatsObservation in
def checkDeleteGate (ctx : Ctx) : IO Unit := do
  let ok := EmptyMasterVerdict.act
  check ctx "delete gate: fresh verdict act, successor valid, UID stable, lease held → delete"
    (okB (deleteGate ok true true true))
  check ctx "delete gate: operator LOST THE LEASE → refuse (item 5)"
    (okB (deleteGate ok true true false) == false)
  check ctx "delete gate: target pod UID changed across the observation (replaced) → refuse"
    (okB (deleteGate ok true false true) == false)
  check ctx "delete gate: successor invalid on the post-read map → refuse"
    (okB (deleteGate ok false true true) == false)
  check ctx "delete gate: fresh verdict is skip → refuse regardless of the rest"
    (okB (deleteGate (.skip "unknown") true true true) == false)
  check ctx "delete gate: refusal reasons name the failing check"
    (match deleteGate ok true true false with | .error r => (r.splitOn "lease").length > 1 | .ok _ => false)

def run : IO UInt32 := do
  let ctx : Ctx := { failures := ← IO.mkRef [], count := ← IO.mkRef 0 }
  checkObserve ctx
  checkRequestResolve ctx
  checkGate ctx
  checkAdvanceHold ctx
  checkAdvanceComplete ctx
  checkJson ctx
  checkEpisodes ctx
  checkJudgeRefusals ctx
  checkJudgeAcceptance ctx
  checkStatsObservation ctx
  checkDeleteGate ctx
  let failures ← ctx.failures.get
  let n ← ctx.count.get
  IO.println s!"1..{n}"
  if failures.isEmpty then
    IO.println s!"# {n} checks passed"
    return 0
  else
    IO.println s!"# FAILED: {failures}"
    return 1

end FlareOperator.UnitTests

def main : IO UInt32 := FlareOperator.UnitTests.run
