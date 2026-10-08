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
import FlareOperator.Migration.Provision
import FlareOperator.Server.TopologyBroadcast
import FlareOperator.StateMachine.TopologyObservation
import FlareOperator.Metrics.Prometheus
import FlareOperator.StateMachine.ReplicaRepair
import FlareOperator.StateMachine.SyncEvidence
import FlareOperator.StateMachine.StatsObservation
import FlareOperator.StateMachine.FollowEvidence
import FlareOperator.StateMachine.K8sReconciler
import FlareOperator.StateMachine.NodeMapRecovery
import FlareOperator.K8s.Bridge
import FlareOperator.E2E.TraceMatch
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.PromotionTimeline
import FlareOperator.StateMachine.SourceEligibility
import FlareOperator.StateMachine.RebuildConcurrency
import FlareOperator.StateMachine.CopyDiscardApproval
import FlareOperator.StateMachine.PromotionEvidence

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

/-- Ledger after the first observation of 7 drops to the slave (requested as
    possibly unrepaired since review 2026-10-06; the counter is recorded). -/
def l1 : Ledger := (observe empty masterKey [(slaveKey, 7)]).1

def drops (l : Ledger) (m : String) (obs : List (String × Nat)) : List (String × Nat) :=
  (observe l m obs).2.1

def checkObserve (ctx : Ctx) : IO Unit := do
  check ctx "first observation of a non-zero count is a POSSIBLY UNREPAIRED request (no longer a silent baseline)"
    (drops empty masterKey [(slaveKey, 7)] == [(slaveKey, 7)] && l1.initialized == true)
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

/-- SAF-10c: a destination whose continuous follower owns the repair. -/
def ownEp : String := "3:abc"
def following (applied : Nat) (epoch : String := ownEp) : FollowReading :=
  { complete := true, enabled := true, state := some "following", appliedLsn := some applied, sourceEpoch := some epoch }
def disconnected : FollowReading := { complete := true, enabled := true, state := some "disconnected", appliedLsn := some 5, sourceEpoch := some ownEp }
def rebuild : FollowReading := { complete := true, enabled := true, state := some "needs_rebuild", appliedLsn := some 5, sourceEpoch := some ownEp }
def unreadable : FollowReading := {}
/-- A complete reply from a flared without a follower (tch): not in the mode. -/
def noFollower : FollowReading := { complete := true }

def checkFollowOwnership (ctx : Ctx) : IO Unit := do
  check ctx "the mode on and following/initial_sync/disconnected/error own; needs_rebuild, idle, off and unreadable do not"
    (ownedByFollower (following 1) && ownedByFollower disconnected
      && ownedByFollower { enabled := true, state := some "error" }
      && ownedByFollower { enabled := true, state := some "initial_sync" }
      && !ownedByFollower rebuild
      && !ownedByFollower { enabled := true, state := some "idle" }
      && !ownedByFollower { enabled := false, state := some "following" }
      && !ownedByFollower unreadable)
  check ctx "a COMPLETE reply without follower keys (tch, older flared) is NOT unreadable: not owned, ordinary repair"
    (!noFollower.unreadable && ownershipAtRequest noFollower == some false
      && (advanceOwned { dest := slaveKey, masterKey := masterKey, nodeKey := some slaveKey, owned := true } noFollower).2 == .handedOver)
  check ctx "at request time an unreadable follower is Unknown: neither owned nor not-owned"
    (ownershipAtRequest unreadable == none && ownershipAtRequest (following 1) == some true
      && ownershipAtRequest rebuild == some false)
  let lReq := request l1 masterKey slaveKey 3
  let lOwn := holdOwned lReq slaveKey (some 100) (some ownEp)
  let e := lOwn.entries.head?
  check ctx "holding records ownership, a visible reason, the bar and its epoch"
    ((e.map (·.owned)) == some true && (e.bind (·.hold)) == some "owned by continuous replication"
      && (e.bind (·.mustReach)) == some 100 && (e.bind (·.barEpoch)) == some ownEp)
  check ctx "a later drop in the same epoch raises the bar and never lowers it; a new epoch replaces it"
    (((holdOwned lOwn slaveKey (some 150) (some ownEp)).entries.head?.bind (·.mustReach)) == some 150
      && ((holdOwned lOwn slaveKey (some 50) (some ownEp)).entries.head?.bind (·.mustReach)) == some 100
      && ((holdOwned lOwn slaveKey (some 7) (some "4:new")).entries.head?.bind (·.mustReach)) == some 7
      && ((holdOwned lOwn slaveKey (some 7) (some "4:new")).entries.head?.bind (·.barEpoch)) == some "4:new")
  let lRes := (resolve lOwn state).1
  check ctx "an owned request is never planned for demotion while the gate is open"
    ((plan lRes true "").2 == [] && ((plan lRes true "").1.entries.head?.bind (·.hold)) == some "owned by continuous replication")
  let lUnk := (resolve (holdOwned lReq slaveKey (some 100) (some ownEp) "follower state unknown (stats unreadable)") state).1
  check ctx "a request held on an unreadable follower is not demoted either"
    ((plan lUnk true "").2 == [])
  check ctx "following at 99 keeps; following at 100 closes without a rebuild"
    ((advanceOwnedAll lRes [(slaveKey, following 99)]).2 == []
      && (advanceOwnedAll lRes [(slaveKey, following 100)]).2.map (·.2) == [.closed]
      && (advanceOwnedAll lRes [(slaveKey, following 100)]).1.entries == [])
  check ctx "a BIGGER position in ANOTHER epoch does not close: it is a different number line"
    ((advanceOwnedAll lRes [(slaveKey, following 100000 "9:other")]).2 == []
      && ((advanceOwnedAll lRes [(slaveKey, following 100000 "9:other")]).1.entries.head?.map (·.owned)) == some true)
  check ctx "a disconnected follower's position is not trusted for closing, but ownership continues"
    ((advanceOwnedAll lRes [(slaveKey, disconnected)]).2 == []
      && ((advanceOwnedAll lRes [(slaveKey, disconnected)]).1.entries.head?.map (·.owned)) == some true)
  check ctx "a TRANSIENT stats failure keeps the hold and hands nothing over (no rebuild on a probe hiccup)"
    ((advanceOwnedAll lRes [(slaveKey, unreadable)]).2 == []
      && ((advanceOwnedAll lRes [(slaveKey, unreadable)]).1.entries.head?.map (·.owned)) == some true
      && ((advanceOwnedAll lRes [(slaveKey, unreadable)]).1.entries.head?.bind (·.hold)) == some "follower state unknown (stats unreadable)"
      && (plan (advanceOwnedAll lRes [(slaveKey, unreadable)]).1 true "").2 == [])
  check ctx "after the hiccup a readable pass resumes: following past the bar closes"
    ((advanceOwnedAll (advanceOwnedAll lRes [(slaveKey, unreadable)]).1 [(slaveKey, following 100)]).2.map (·.2) == [.closed])
  check ctx "needs_rebuild hands the entry to the ordinary path, keeping its drops and node key"
    ((advanceOwnedAll lRes [(slaveKey, rebuild)]).2.map (·.2) == [.handedOver]
      && ((advanceOwnedAll lRes [(slaveKey, rebuild)]).1.entries.head?.map (·.owned)) == some false
      && ((advanceOwnedAll lRes [(slaveKey, rebuild)]).1.entries.head?.map (·.drops)) == some 3
      && (plan (advanceOwnedAll lRes [(slaveKey, rebuild)]).1 true "").2.length == 1)
  check ctx "an owned entry with no recorded bar stays owned and is not closed by position"
    ((advanceOwnedAll (holdOwned lReq slaveKey none none) [(slaveKey, following 1000)]).2 == []
      && ((advanceOwnedAll (holdOwned lReq slaveKey none none) [(slaveKey, following 1000)]).1.entries.head?.map (·.owned)) == some true)
  check ctx "ownership, bar and epoch survive the status round trip (an operator restart)"
    (match Ledger.fromJson? (Ledger.toJson lRes) with
      | some back => back == lRes && (back.entries.head?.map (·.owned)) == some true
                     && (back.entries.head?.bind (·.mustReach)) == some 100
                     && (back.entries.head?.bind (·.barEpoch)) == some ownEp
      | none => false)

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
    (okB (deleteGate ok true true true true))
  check ctx "delete gate: operator LOST THE LEASE → refuse (item 5)"
    (okB (deleteGate ok true true true false) == false)
  check ctx "delete gate: target pod UID changed across the observation (replaced) → refuse"
    (okB (deleteGate ok true true false true) == false)
  check ctx "delete gate: successor invalid on the post-read map → refuse"
    (okB (deleteGate ok false true true true) == false)
  check ctx "delete gate: fresh verdict is skip → refuse regardless of the rest"
    (okB (deleteGate (.skip "unknown") true true true true) == false)
  check ctx "delete gate: refusal reasons name the failing check"
    (match deleteGate ok true true true false with | .error r => (r.splitOn "lease").length > 1 | .ok _ => false)


-- ===========================================================================
-- SAF-10c: FollowEvidence — purpose-specific eligibility, Unknown handling,
-- failover ranking; and the FSM-side shaping / read withholding.
-- ===========================================================================

def fb : FollowEvidence.Bounds := {}   -- fresh 5 s, read lag 1000, promotion lag 100
def fm : FollowEvidence.MasterReading := { complete := true, epoch := some "2:abc", head := some 1000 }
def fmUnreadable : FollowEvidence.MasterReading := {}
def fmNoEpoch : FollowEvidence.MasterReading := { complete := true, head := some 1000 }

/-- A follower reading: `st` state, `applied` position, `seenAgo` seconds
    since the master's position was observed (node clock 1000). -/
def fr (st : String) (applied : Nat) (seenAgo : Nat := 0) (ep : String := "2:abc")
    : FollowEvidence.Reading :=
  { complete := true, enabled := some true, state := some st, sourceEpoch := some ep,
    appliedLsn := some applied, sourceLsn := some 1000, sourceObservedAt := some (1000 - seenAgo),
    lastProgressAt := some 1000, nodeTime := some 1000 }
def frOff : FollowEvidence.Reading := { complete := true, enabled := some false, state := some "idle" }
def frCut : FollowEvidence.Reading := {}
def frNoState : FollowEvidence.Reading := { complete := true, enabled := some true }

def judgeR (r : FollowEvidence.Reading) (m : FollowEvidence.MasterReading := fm) :=
  FollowEvidence.judge .read fb r m
def judgeP (r : FollowEvidence.Reading) (m : FollowEvidence.MasterReading := fm) :=
  FollowEvidence.judge .promote fb r m
def hasWord (v : FollowEvidence.Verdict) (w : String) : Bool := (v.reason.splitOn w).length > 1

def checkFollowJudge (ctx : Ctx) : IO Unit := do
  check ctx "an unreadable reply is Unknown for reads and promotion (never healthy, never unfit)"
    ((judgeR frCut).isUnknown && (judgeP frCut).isUnknown
      && FollowEvidence.unfitReason frCut (some "2:abc") == none)
  check ctx "a complete reply with the mode off is not-in-mode: this module has no say"
    (match judgeR frOff, judgeP frOff with | .notInMode _, .notInMode _ => true | _, _ => false)
  check ctx "a complete reply in the mode without a state is Unknown"
    ((judgeR frNoState).isUnknown)
  check ctx "following, same epoch, fresh, caught up: eligible for reads and promotion"
    ((judgeR (fr "following" 1000)).isEligible && (judgeP (fr "following" 1000)).isEligible)
  check ctx "disconnected is ineligible (not unfit): resuming is the follower's job, but nothing is proven"
    (!(judgeR (fr "disconnected" 1000)).isEligible && !(judgeR (fr "disconnected" 1000)).isUnknown
      && FollowEvidence.unfitReason (fr "disconnected" 1000) (some "2:abc") == none)
  check ctx "following another epoch is ineligible AND unfit (a copy of another history)"
    (hasWord (judgeR (fr "following" 1000 0 "1:old")) "another history"
      && (FollowEvidence.unfitReason (fr "following" 1000 0 "1:old") (some "2:abc")).isSome)
  check ctx "a stale observation (6 s > 5 s) is ineligible; 5 s is still fresh"
    (hasWord (judgeR (fr "following" 1000 6)) "stale" && (judgeR (fr "following" 1000 5)).isEligible)
  check ctx "clock rollback cannot turn an old observation into fresh evidence"
    ((judgeR { fr "following" 1000 with sourceObservedAt := some 1001 }).isUnknown)
  check ctx "lag 500: within the read bound (1000) but over the promotion bound (100)"
    ((judgeR (fr "following" 500)).isEligible && hasWord (judgeP (fr "following" 500)) "bound")
  check ctx "lag exactly at the promotion bound is eligible"
    ((judgeP (fr "following" 900)).isEligible)
  check ctx "an applied position AHEAD of the master's head is ineligible (another sequence space)"
    (hasWord (judgeR (fr "following" 1100)) "ahead")
  check ctx "an unreadable master, or a master without a source epoch, makes the verdict Unknown"
    ((judgeR (fr "following" 1000) fmUnreadable).isUnknown && (judgeR (fr "following" 1000) fmNoEpoch).isUnknown)
  check ctx "needs_rebuild, initial_sync and idle are unfit; following the master's epoch is not"
    ((FollowEvidence.unfitReason (fr "needs_rebuild" 1000) (some "2:abc")).isSome
      && (FollowEvidence.unfitReason (fr "initial_sync" 1000) (some "2:abc")).isSome
      && (FollowEvidence.unfitReason (fr "idle" 1000) (some "2:abc")).isSome
      && FollowEvidence.unfitReason (fr "following" 1000) (some "2:abc") == none)
  check ctx "survival uses the promotion bound"
    ((FollowEvidence.judge .survive fb (fr "following" 900) fm).isEligible
      && !(FollowEvidence.judge .survive fb (fr "following" 500) fm).isEligible)

def cNodes : List (String × Int × Option FollowEvidence.Reading) :=
  [("a", 0, some (fr "following" 900)), ("b", 0, some (fr "following" 1000)),
   ("c", 0, some (fr "disconnected" 1000)), ("d", 0, some (fr "needs_rebuild" 1000)),
   ("e", 0, some frOff), ("f", 0, some frCut), ("g", 0, none)]

def cls1 := FollowEvidence.classify fb [] cNodes [(0, fm)]

def checkFollowClassify (ctx : Ctx) : IO Unit := do
  check ctx "ranked = proven-current followers, highest applied position first"
    (cls1.1.ranked == ["b", "a"])
  check ctx "disconnected and never-observed nodes are unproven; only needs_rebuild is unfit"
    (cls1.1.unproven == ["c", "f", "g"] && cls1.1.unfit == ["d"]
      && cls1.1.readWithheld == ["c", "d", "f", "g"])
  check ctx "operator cold start withholds unknown replicas but preserves explicit non-WAL policy"
    (!cls1.1.readWithheld.contains "e" && cls1.1.readWithheld.contains "f"
      && cls1.1.readWithheld.contains "g" && cls1.1.unproven.contains "f")
  let recovered := FollowEvidence.classify fb cls1.2.1
    [("f", 0, some (fr "following" 1000)), ("g", 0, some frOff)] [(0, fm)]
  check ctx "fresh catch-up or confirmed non-WAL mode restores eligibility after cold-start withholding"
    (recovered.1.readWithheld == [] && recovered.1.ranked == ["f"])
  let cutAgain := FollowEvidence.classify fb recovered.2.1
    [("f", 0, some frCut), ("g", 0, none)] [(0, fm)]
  check ctx "a recovered WAL follower is withheld on the next stats failure without marking its copy unfit"
    (cutAgain.1.readWithheld == ["f"] && cutAgain.1.unfit == [])
  check ctx "the mode memory records what was readable: a-d in the mode, e out, f and g unchanged"
    (cls1.2.1.lookup "a" == some true && cls1.2.1.lookup "d" == some true
      && cls1.2.1.lookup "e" == some false && cls1.2.1.lookup "f" == none && cls1.2.1.lookup "g" == none)
  let cls2 := FollowEvidence.classify fb [("f", true), ("g", true)] cNodes [(0, fm)]
  check ctx "a node remembered in the mode that is unreadable or not probed is Unknown: unproven and withheld, never unfit"
    (cls2.1.unproven.contains "f" && cls2.1.unproven.contains "g"
      && cls2.1.readWithheld.contains "f" && cls2.1.readWithheld.contains "g"
      && !cls2.1.unfit.contains "f" && !cls2.1.unfit.contains "g")
  let cls3 := FollowEvidence.classify fb [] cNodes []
  check ctx "without a master reading nothing is proven: no ranked, following nodes unproven and withheld"
    (cls3.1.ranked == [] && cls3.1.unproven.contains "a" && cls3.1.readWithheld.contains "a"
      && cls3.1.unfit == ["d"])
  -- SAF-08: a reply from a different flared process than last pass is Unknown.
  let withBoot := fun (r : FollowEvidence.Reading) (b : Nat) => { r with bootId := some b }
  let (m1, boots1) := FollowEvidence.markProcessChanges []
    [("b", 0, some (withBoot (fr "following" 1000) 7))]
  check ctx "SAF-08: a node seen for the first time is not marked (an operator restart does not withhold everyone)"
    (m1.all (fun (_, _, r?) => !((r?.map (·.processChanged)).getD false)) && boots1 == [("b", 7)])
  let (m2, boots2) := FollowEvidence.markProcessChanges boots1
    [("b", 0, some (withBoot (fr "following" 1000) 8))]
  let c2 := FollowEvidence.classify fb [("b", true)] m2 [(0, fm)]
  check ctx "SAF-08: a changed boot id makes an otherwise eligible follower Unknown: withheld and not promotable"
    (c2.1.readWithheld == ["b"] && c2.1.unproven == ["b"] && c2.1.ranked == [] && c2.1.unfit == [])
  let (m3, _) := FollowEvidence.markProcessChanges boots2
    [("b", 0, some (withBoot (fr "following" 1000) 8))]
  let c3 := FollowEvidence.classify fb [("b", true)] m3 [(0, fm)]
  check ctx "SAF-08: the second consistent reading of the new process restores eligibility"
    (c3.1.readWithheld == [] && c3.1.ranked == ["b"])
  let (_, boots4) := FollowEvidence.markProcessChanges [("b", 8), ("z", 3)]
    [("b", 0, none)]
  check ctx "SAF-08: an unprobed node keeps its last boot id; a node no longer listed is forgotten"
    (boots4 == [("b", 8)])
  let (m5, _) := FollowEvidence.markProcessChanges [("e", 1)] [("e", 0, some (withBoot frOff 2))]
  check ctx "SAF-08: a process change of a node out of the mode keeps the legacy policy"
    (!(FollowEvidence.classify fb [("e", false)] m5 [(0, fm)]).1.readWithheld.contains "e")
  let farBehind : FollowEvidence.Reading := { fr "disconnected" 1000 with sourceLsn := some 500000, appliedLsn := some 1000 }
  check ctx "failover bound: a follower more backlog than the bound behind is unfit (no failover promotion)"
    ((FollowEvidence.unfitReason farBehind (some "2:abc") 100000).isSome
      && (FollowEvidence.unfitReason farBehind (some "2:abc") 0).isNone)
  let nearBehind : FollowEvidence.Reading := { fr "disconnected" 1000 with sourceLsn := some 50000, appliedLsn := some 1000 }
  check ctx "failover bound: a follower within the bound stays a last-resort candidate (unproven, not unfit)"
    ((FollowEvidence.unfitReason nearBehind (some "2:abc") 100000).isNone)
  let clsFar := FollowEvidence.classify { fb with failoverMaxLag := 100000 } [("b", true)] [("b", 0, some farBehind)] [(0, fm)]
  check ctx "failover bound: classify lists the far-behind follower as unfit"
    (clsFar.1.unfit == ["b"] && clsFar.1.ranked == [])
  check ctx "probe policy: in the mode every tick; out of the mode every interval; never read: now"
    (FollowEvidence.shouldProbe [("x", true)] "x" 7 30 && !FollowEvidence.shouldProbe [("x", false)] "x" 7 30
      && FollowEvidence.shouldProbe [("x", false)] "x" 60 30 && FollowEvidence.shouldProbe [] "x" 7 30)
  let (changed, now) := FollowEvidence.changedSummaries [("a", (cls1.2.2.head?.map (·.summary)).getD "")] cls1.2.2
  check ctx "only changed judgements are reported; the summaries are carried forward"
    (!(changed.map Prod.fst).contains "a" && (changed.map Prod.fst).contains "b" && now.length == cls1.2.2.length)

def s3 : FlareClusterState :=
  ({ nodeMap := [("m", node .Master .Active 0 "m"), ("s1", node .Slave .Active 0 "s1"),
                 ("s2", node .Slave .Active 0 "s2"), ("s3", node .Slave .Active 0 "s3"),
                 ("dn", node .Slave .Down 0 "dn")],
     nodeMapVersion := 1 } : FlareClusterState).rebuildPartitionMap

def slavesOf (s : FlareClusterState) : List String :=
  ((s.partitionMap.find? (·.1 == 0)).map (·.2.slaves)).getD []

def checkFollowShaping (ctx : Ctx) : IO Unit := do
  let shaped := K8sReconciler.shapePromotionCandidates ["s2"] ["s3"] [] s3
  check ctx "shaping: excluded removed, ranked first, the rest in map order; nodeMap untouched"
    (slavesOf shaped == ["s3", "s1", "dn"] && shaped.nodeMap == s3.nodeMap)
  check ctx "shaping: unproven go last; empty lists are the identity"
    (slavesOf (K8sReconciler.shapePromotionCandidates [] [] ["s1"] s3) == ["s2", "s3", "dn", "s1"]
      && (K8sReconciler.shapePromotionCandidates [] [] [] s3).partitionMap == s3.partitionMap)
  check ctx "the successor search sees the shaped order (proven follower first)"
    ((shaped.partitionMap.find? (·.1 == 0)).bind (fun (_, p) => K8sReconciler.findActiveSuccessor shaped p 0) == some "s3")
  check ctx "drain shaping (unfit ++ unproven excluded) can leave NO successor: the guard then keeps the master"
    (slavesOf (K8sReconciler.shapePromotionCandidates ["s1", "s2", "s3", "dn"] [] [] s3) == [])
  let held := K8sReconciler.withholdReads ["s1", "m", "dn"] s3.nodeMap
  check ctx "withholding: a listed Slave gets balance 0; master, Down corpse and unlisted slaves untouched; keys preserved"
    ((held.lookup "s1").map (·.balance) == some 0 && (held.lookup "m").map (·.balance) == some 100
      && (held.lookup "dn") == s3.nodeMap.lookup "dn" && (held.lookup "s2").map (·.balance) == some 100
      && held.map Prod.fst == s3.nodeMap.map Prod.fst)
  check ctx "the masterless refill skips an excluded (unfit) Active slave"
    (let noMaster : FlareClusterState := { s3 with nodeMap := s3.nodeMap.filter (·.1 != "m") }
     let refilled := K8sReconciler.promoteMasterlessPartition noMaster 0 ["s1", "s2", "s3"] [] [] ["s1"]
     (refilled.nodeMap.find? (fun kv => kv.2.role == FlareRole.Master)).map (·.1) == some "s2")
  check ctx "classify reports a follower that declared needs_rebuild, with flared's reason"
    (let r := { fr "needs_rebuild" 1000 with lastReason := some "epoch_mismatch" }
     (FollowEvidence.classify fb [] [("d", 0, some r)] [(0, fm)]).1.needsRebuild == [("d", "epoch_mismatch")])
  check ctx "requestRebuild adds one un-owned, resolved request per node and is idempotent; plan then demotes it"
    (let (l1, a1) := requestRebuild empty masterKey slaveKey
     let (l2, a2) := requestRebuild l1 masterKey slaveKey
     a1 && !a2 && l2.entries.length == 1
       && (l1.entries.head?.map (fun e => e.nodeKey == some slaveKey && !e.owned && e.drops == 0)) == some true
       && ((plan l1 true "").2.map Prod.fst) == [slaveKey])
  check ctx "requestRebuild adds nothing for a node that already has an (owned) entry"
    (let owned := holdOwned (resolve (request empty masterKey slaveKey 1) state).1 slaveKey (some 5) (some ownEp)
     !(requestRebuild owned masterKey slaveKey).2)
  -- The two routes to a rebuild request RACE (design §5.4): a drop counted
  -- for the node (refused forwards after an epoch change) and the
  -- follower's own needs_rebuild. In either order there is exactly one
  -- entry, un-owned, resolved to the node, demoted once by plan.
  check ctx "race: drop request first, then the follower's declaration → one entry, drops kept, one demotion"
    (let l1 := (resolve (request empty masterKey slaveKey 2) state).1
     let (l2, added) := requestRebuild l1 masterKey slaveKey
     !added && l2.entries.length == 1 && (l2.entries.head?.map (·.drops)) == some 2
       && ((plan l2 true "").2.map Prod.fst) == [slaveKey])
  check ctx "race: the follower's declaration first, then a drop → one entry with the drops added, one demotion"
    (let (l1, added) := requestRebuild empty masterKey slaveKey
     let l2 := (resolve (request l1 masterKey slaveKey 3) state).1
     added && l2.entries.length == 1 && (l2.entries.head?.map (·.drops)) == some 3
       && (l2.entries.head?.map (·.owned)) == some false
       && ((plan l2 true "").2.map Prod.fst) == [slaveKey])
  check ctx "race: a drop on an OWNED entry and the follower's declaration in the same pass → hand-over, single un-owned request"
    (let owned := holdOwned (resolve (request empty masterKey slaveKey 1) state).1 slaveKey (some 5) (some ownEp)
     let (afterAdv, steps) := advanceOwnedAll owned [(slaveKey, rebuild)]
     let (l2, added) := requestRebuild afterAdv masterKey slaveKey
     steps.map (·.2) == [.handedOver] && !added && l2.entries.length == 1
       && (l2.entries.head?.map (·.owned)) == some false
       && ((plan l2 true "").2.map Prod.fst) == [slaveKey])
  check ctx "deleteGate: an unproven surviving follower refuses the delete"
    (match StatsObservation.deleteGate .act true false true true with
     | .error r => (r.splitOn "continuous-replication").length > 1
     | .ok _ => false)

private def checkMemoryConfig (ctx : Ctx) : IO Unit := do
  let empty : RocksdbConfigSpec := {}
  check ctx "unset memory settings preserve flared defaults" (!empty.hasAny && empty.toExtraConf == "")
  let r : RocksdbConfigSpec := {
    blockCacheSizeMb := some 64
    writeBufferSizeMb := some 16
    maxWriteBufferNumber := some 3
    walTtlSeconds := some 900 }
  let text := r.toExtraConf
  check ctx "memory config renders all three options alongside WAL retention"
    (r.hasAny && text.splitOn "\n" == ["rocksdb-block-cache-size-mb = 64",
      "rocksdb-write-buffer-size-mb = 16", "rocksdb-max-write-buffer-number = 3",
      "rocksdb-wal-ttl-seconds = 900"])
  for r in ([{ blockCacheSizeMb := some 64 }, { writeBufferSizeMb := some 16 },
      { maxWriteBufferNumber := some 3 }] : List RocksdbConfigSpec) do
    check ctx "a memory-only spec is not ignored" r.hasAny
  let yaml := FlareOperator.Migration.Provision.rocksdbSpecYaml r
  check ctx "migration preserves the memory budget"
    ((yaml.splitOn "blockCacheSizeMb: 64").length == 2 &&
     (yaml.splitOn "writeBufferSizeMb: 16").length == 2 &&
     (yaml.splitOn "maxWriteBufferNumber: 3").length == 2)

/-- SAF-11: the breaker counts capacity unavailable NOW, so a majority
    outage spread over ticks trips it. -/
private def checkBreakerUnavailable (ctx : Ctx) : IO Unit := do
  let node := fun (h : String) (role : FlareRole) (st : FlareState) =>
    (s!"{h}:12121", ({ serverName := h, serverPort := 12121, role, state := st, partition := 0 } : FlareNode))
  let cs := fun (ns : List (String × FlareNode)) =>
    ({ FlareClusterState.default with nodeMap := ns } : FlareClusterState)
  let cfg : CircuitBreakerConfig := {}
  let unavail := K8sReconciler.breakerUnavailableKeys
  let trips := fun (st : FlareClusterState) (dead live : List String) =>
    (K8sReconciler.circuitBreakerDecision (unavail st dead live).length st.nodeMap.length cfg false).1
      == .RecoveryRefill
  let k := fun (h : String) => s!"{h}:12121"
  -- 4 nodes, one partition master + 3 slaves (the 4→1 E2E shape).
  let t1 := cs [node "a" .Master .Active, node "b" .Slave .Active, node "c" .Slave .Active, node "d" .Slave .Active]
  check ctx "tick 1: one of four dead (25%) does not trip"
    (!trips t1 [k "b"] [k "a", k "c", k "d"])
  -- After failover b is Proxy+Down; c dies in the next tick.
  let t2 := cs [node "a" .Master .Active, node "b" .Proxy .Down, node "c" .Slave .Active, node "d" .Slave .Active]
  check ctx "tick 2: a second death with the first already Down (50%) trips"
    (trips t2 [k "c"] [k "a", k "d"])
  check ctx "the old per-tick count (1 of 4 in tick 2) would not have tripped"
    ((K8sReconciler.circuitBreakerDecision 1 4 cfg false).1 == .AfterHandleFailover)
  check ctx "a Prepare node with no live pod counts; one with a live pod does not"
    (unavail (cs [node "a" .Master .Active, node "p" .Slave .Prepare, node "q" .Slave .Prepare]) [] [k "a", k "q"]
      == [k "p"])
  check ctx "a healthy proxy is not unavailable"
    (unavail (cs [node "a" .Master .Active, node "x" .Proxy .Active]) [] [k "a", k "x"] == [])
  check ctx "a node dead this tick is counted once even if also Down-eligible"
    ((unavail (cs [node "a" .Master .Active, node "b" .Slave .Active]) [k "b"] [k "a"]).length == 1)
  let big := cs ((List.range 8).map fun i =>
    node s!"n{i}" (if i == 0 then .Master else .Slave) (if i == 7 then .Down else .Active))
  let pair := cs [node "a" .Master .Active, node "b" .Slave .Active]
  check ctx "read-unavailable-error renders into extra.conf only when set"
    (({ readUnavailableError := some true } : RocksdbConfigSpec).toExtraConf == "read-unavailable-error = true"
      && ({ readUnavailableError := some false } : RocksdbConfigSpec).toExtraConf == "read-unavailable-error = false"
      && ({} : RocksdbConfigSpec).toExtraConf == ""
      && ({ readUnavailableError := some true } : RocksdbConfigSpec).hasAny)
  check ctx "continuous replication flags render into extra.conf, so a spec change cannot drop them"
    (({ replIdentityForward := some true, replFollowEnabled := some true, replFollowPollIntervalUsec := some 200000 } : RocksdbConfigSpec).toExtraConf
      == "repl-identity-forward = true\nrepl-follow-enabled = true\nrepl-follow-poll-interval-usec = 200000")
  check ctx "maxTotalThreadQueue renders into extra.conf"
    (({ maxTotalThreadQueue := some 200000 } : RocksdbConfigSpec).toExtraConf == "max-total-thread-queue = 200000")
  check ctx "breaker floor: one dead node of two (50%) does not trip with the default minimum of 2"
    (!trips pair [k "a"] [k "b"])
  check ctx "breaker floor: minUnavailableToTrip = 1 restores tripping on a single death"
    ((K8sReconciler.circuitBreakerDecision 1 2 { cfg with minUnavailableToTrip := 1 } false).1 == .RecoveryRefill)
  check ctx "breaker floor: two unavailable of four (50%) still trips"
    ((K8sReconciler.circuitBreakerDecision 2 4 cfg false).1 == .RecoveryRefill)
  let st := cs [node "a" .Master .Active, node "b" .Slave .Prepare, node "c" .Slave .Active]
  check ctx "NotReady streaks: an Active node's streak grows; a Prepare node's restarts at 0"
    (K8sReconciler.unreadyStreaks [(k "b", 9), (k "c", 2)] [k "b", k "c"] st == [(k "c", 3)])
  let stAct := cs [node "a" .Master .Active, node "b" .Slave .Active, node "c" .Slave .Active]
  check ctx "NotReady streaks: a node that just became Active starts from 1, not from its Prepare streak"
    (K8sReconciler.unreadyStreaks (K8sReconciler.unreadyStreaks [] [k "b"] st) [k "b"] stAct == [(k "b", 1)])
  check ctx "NotReady streaks: a node that turns Ready drops out"
    (K8sReconciler.unreadyStreaks [(k "c", 4)] [] stAct == [])
  check ctx "one long-Down node in eight (12%) does not trip"
    (!trips big [] ((List.range 7).map fun i => k s!"n{i}"))

private def checkTopologyDelivery (ctx : Ctx) : IO Unit := do
  check ctx "only a complete OK response confirms topology delivery"
    (FlareOperator.Server.topologyAckAccepted "OK\r\n")
  for reply in ["", "OK", "SERVER_ERROR node sync error\r\n", "CLIENT_ERROR format error\r\n", "OK\r\nextra"] do
    check ctx "missing, truncated or rejected topology reply remains unconfirmed"
      (!FlareOperator.Server.topologyAckAccepted reply)
  check ctx "first failed send retains its committed version"
    (FlareOperator.Server.pendingTopologyAfterAttempt none 100 false == some 100)
  check ctx "subsequent failures retain earliest pending version even as map advances"
    (FlareOperator.Server.pendingTopologyAfterAttempt (some 100) 110 false == some 100)
  check ctx "confirmed latest map clears pending delivery"
    (FlareOperator.Server.pendingTopologyAfterAttempt (some 100) 110 true == none)
  let trig := fun (moved : Bool) (pending : Option Nat) (held active : Nat) =>
    ({ versionMoved := moved, pending, repairHeld := held, activeNotReady := active } :
      FlareOperator.Server.BroadcastTriggers)
  check ctx "a pass at rest with nothing pending does not send"
    (!(trig false none 0 0).any)
  check ctx "each trigger alone sends"
    ((trig true none 0 0).any && (trig false (some 7) 0 0).any &&
     (trig false none 1 0).any && (trig false none 0 1).any)
  check ctx "startup republish shape: pending only, version unchanged"
    ((trig false (some 7) 0 0).pendingOnly)
  check ctx "pending plus any other reason is not attributable to pending alone"
    (!(trig true (some 7) 0 0).pendingOnly && !(trig false (some 7) 1 0).pendingOnly &&
     !(trig false (some 7) 0 1).pendingOnly && !(trig false none 0 0).pendingOnly)
  let g := FlareOperator.Server.startupGeneration
  let u := FlareOperator.Server.generationUnit
  check ctx "SAF-09: a recreated Lease (transitions 0) still yields a generation above the persisted one"
    (g 0 (2 * u + 9) == 3)
  check ctx "SAF-09: a Lease count above the persisted generation wins"
    (g 5 (3 * u + 7) == 5)
  check ctx "SAF-09: equal Lease count and persisted generation still move up by one"
    (g 3 (3 * u + 1) == 4)
  check ctx "SAF-09: a fresh cluster starts at generation 1"
    (g 0 0 == 1)
  check ctx "SAF-09: the first version of a new leader is above the persisted version"
    (FlareOperator.Server.startupVersion 0 (2 * u + 9) > 2 * u + 9)
  check ctx "SAF-09: a version is sent only when the durable record holds it"
    (FlareOperator.Server.persistedCovers 10 10 && FlareOperator.Server.persistedCovers 11 10
      && !FlareOperator.Server.persistedCovers 9 10)
  check ctx "trigger label names every reason"
    ((trig false (some 7) 0 0).label == "versionMoved=false pending=v7 repairHeld=0 activeNotReady=0")

private def checkTopologyObservation (ctx : Ctx) : IO Unit := do
  let parse := FlareOperator.TopologyObservation.reportedVersion
  let judge := FlareOperator.TopologyObservation.judge
  check ctx "complete stats expose the applied topology version"
    (parse "STAT node_map_version 42\r\nEND\r\n" == some 42)
  for reply in ["STAT node_map_version 42\r\n", "END\r\n", "STAT node_map_version bad\r\nEND\r\n",
      "STAT node_map_version 42\r\nSTAT node_map_version 43\r\nEND\r\n"] do
    check ctx "missing, truncated, invalid or duplicate versions are Unknown" (parse reply == none)
  check ctx "observed older map needs delivery, not failover"
    (judge 42 (some "uid-a") (some "uid-a") (some 41) == .behind)
  check ctx "same-version observation is current"
    (judge 42 (some "uid-a") (some "uid-a") (some 42) == .current)
  check ctx "newer recipient is an authority mismatch, not a lagging recipient"
    (judge 42 (some "uid-a") (some "uid-a") (some 43) == .ahead)
  check ctx "same-name Pod replacement invalidates the reply"
    (judge 42 (some "uid-a") (some "uid-b") (some 42) == .unknown)
  check ctx "missing UID cannot confirm application"
    (judge 42 none none (some 42) == .unknown)
  let old : FlareOperator.TopologyObservation.Sample := {
    nodeKey := "n", uid := some "old", reportedVersion := some 42
    observedAtMs := 1, verdict := .current }
  let fresh := { old with uid := some "new", reportedVersion := none, verdict := .unknown }
  let audit := FlareOperator.TopologyObservation.record { samples := [old, { old with nodeKey := "gone" }] } ["n"] fresh
  check ctx "fresh Unknown replaces old confirmation and removed nodes are pruned"
    (match audit.samples with
     | [s] => s.uid == some "new" && s.verdict == .unknown
     | _ => false)

private def checkTopologyMetrics (ctx : Ctx) : IO Unit := do
  let s : FlareOperator.TopologyObservation.Sample := {
    nodeKey := "n", uid := some "uid", reportedVersion := some 42
    observedAtMs := 1000, verdict := .current }
  let classify := FlareOperator.TopologyObservation.observedVerdict
  check ctx "new desired version invalidates old current verdict"
    (classify 43 1001 60000 (some s) == .behind)
  check ctx "expired current observation becomes Unknown"
    (classify 42 61001 60000 (some s) == .unknown)
  check ctx "future timestamp is Unknown"
    (classify 42 999 60000 (some s) == .unknown)
  check ctx "UID-invalid observation is not rehabilitated by a matching number"
    (classify 42 1001 60000 (some { s with verdict := .unknown }) == .unknown)
  let counts := FlareOperator.TopologyObservation.summarize { samples := [s] } ["n", "unseen"] 43 1001 60000
  check ctx "summary counts fresh lag and missing feedback separately"
    (counts.behind == 1 && counts.unknown == 1 && counts.ahead == 0)
  check ctx "removed recipients do not remain in counts"
    (FlareOperator.TopologyObservation.summarize { samples := [s] } [] 43 1001 60000 == {})
  let metrics ← FlareOperator.Metrics.Prometheus.initMetrics
  metrics.topologyBehindNodes.set 2
  metrics.topologyAheadNodes.set 1
  metrics.topologyUnknownNodes.set 3
  let rolesState : FlareClusterState := { FlareClusterState.default with nodeMap := [
    ("c-nodes-0.c-nodes.ns.svc.cluster.local:12121", { serverName := "c-nodes-0.c-nodes.ns.svc.cluster.local", serverPort := 12121, role := FlareRole.Master, state := FlareState.Active, partition := 0 }),
    ("c-nodes-1.c-nodes.ns.svc.cluster.local:12121", { serverName := "c-nodes-1.c-nodes.ns.svc.cluster.local", serverPort := 12121, role := FlareRole.Slave, state := FlareState.Prepare, partition := 0 })] }
  FlareOperator.Metrics.Prometheus.updateNodeCounts metrics rolesState
  let out ← FlareOperator.Metrics.Prometheus.exportMetrics metrics "unit"
  check ctx "EV-15: one role sample per node, labelled with pod, partition, role and state"
    ((out.splitOn "flare_operator_node_role{cluster=\"unit\",pod=\"c-nodes-0\",partition=\"0\",role=\"master\",state=\"active\"} 1\n").length == 2
      && (out.splitOn "flare_operator_node_role{cluster=\"unit\",pod=\"c-nodes-1\",partition=\"0\",role=\"slave\",state=\"prepare\"} 1\n").length == 2)
  for name in ["flare_operator_topology_observed_behind_nodes", "flare_operator_topology_observed_ahead_nodes", "flare_operator_topology_unknown_nodes"] do
    check ctx "topology gauge is present in actual metrics exporter"
      ((out.splitOn s!"# TYPE {name} gauge").length == 2)

def activationCrd : FlareClusterView :=
  { metadata := { name := some "unit", «namespace» := some "default" }
    spec := { partitions := 1, replicas := 2 } }

def activationState (st : FlareState) : FlareClusterState :=
  { nodeMap := [("a:12121", node .Master .Active 0 "a"), ("b:12121", node .Slave st 0 "b")],
    nodeMapVersion := 7 }

def isOk : Flare.FlareResponse → Bool
  | .OK => true
  | _ => false

def checkReactivation (ctx : Ctx) : IO Unit := do
  -- CI run 37007523101: the operator's PREPARE-REPAIR activated a replica
  -- while flared was still finishing its reconstruction; flared's own report
  -- was then rejected as 0→0, and it retried the whole reconstruction.
  let s := activationState .Active
  let (s', r) := Reconciler.reconcileStep s activationCrd (.NodeState "b" 12121 .Active)
  check ctx "re-activation of an Active node is acknowledged and changes nothing"
    (isOk r && s'.nodeMap == s.nodeMap && s'.nodeMapVersion == s.nodeMapVersion)
  let (_, rReady) := Reconciler.reconcileStep s activationCrd (.NodeState "a" 12121 .Ready)
  check ctx "an Active master reporting Ready again is acknowledged" (isOk rReady)
  let (sd, rDown) := Reconciler.reconcileStep (activationState .Down) activationCrd (.NodeState "b" 12121 .Active)
  check ctx "a Down node still cannot report itself Active"
    (!isOk rDown && sd.nodeMap == (activationState .Down).nodeMap)
  let (sp, rPrep) := Reconciler.reconcileStep (activationState .Prepare) activationCrd (.NodeState "b" 12121 .Active)
  check ctx "Prepare → Active under an Active master is still applied"
    (isOk rPrep && (sp.lookupNode "b:12121").map (·.state) == some .Active)

def holdNode (r : FlareRole) (st : FlareState) (p : Int) (nm : String) (lmo : Int := -1) : FlareNode :=
  { serverName := nm, serverPort := 12121, role := r, state := st, partition := p, lastMasterOf := lmo }

def containsSub (h n : String) : Bool := (h.splitOn n).length > 1

/-- After failover: the dead master is Proxy/Down (lastMasterOf 0), its only
    follower is Active but unfit (too far behind). -/
def holdState : FlareClusterState :=
  ({ nodeMap := [("m", holdNode .Proxy .Down (-1) "m" 0), ("f", holdNode .Slave .Active 0 "f")],
     nodeMapVersion := 5 } : FlareClusterState).rebuildPartitionMap

def masterOf (s : FlareClusterState) : Option String :=
  (s.nodeMap.find? (fun kv => kv.2.role == FlareRole.Master)).map (·.1)

def checkFailoverLagHold (ctx : Ctx) : IO Unit := do
  -- CI-free reproduction (2026-10-03): without the hold, the refill's
  -- last-resort tier crowned the unfit follower in the pass that failed its
  -- master over, so failoverMaxLag protected nothing.
  check ctx "lag hold off: the refill crowns the unfit follower as before"
    (masterOf (K8sReconciler.promoteMasterlessPartition holdState 0 ["f"] [] ["f"] ["f"]) == some "f")
  check ctx "lag hold on, ex-master away: the unfit follower is NOT crowned; the partition stays masterless"
    (masterOf (K8sReconciler.promoteMasterlessPartition holdState 0 ["f"] [] ["f"] ["f"] true) == none)
  check ctx "the held partition is reported with its follower"
    (K8sReconciler.heldForExMaster (K8sReconciler.promoteMasterlessPartition holdState 0 ["f"] [] ["f"] ["f"] true)
      activationCrd ["f"] ["f"] ["f"] == [(0, ["f"])])
  let back : FlareClusterState :=
    ({ holdState with nodeMap := [("m", holdNode .Slave .Prepare 0 "m" 0), ("f", holdNode .Slave .Active 0 "f")] }).rebuildPartitionMap
  check ctx "ex-master back WITH data: it is crowned, not the unfit follower"
    (masterOf (K8sReconciler.promoteMasterlessPartition back 0 ["m", "f"] [] ["m", "f"] ["f"] true) == some "m")
  check ctx "ex-master back and READ empty (known-empty): nothing to wait for, the unfit follower is crowned"
    (masterOf (K8sReconciler.promoteMasterlessPartition back 0 ["m", "f"] [] ["f"] ["f"] true ["m"]) == some "f")
  check ctx "ex-master back but UNREADABLE (neither data-bearing nor known-empty): the hold continues, the unfit follower is NOT crowned (CI 37296281060)"
    (masterOf (K8sReconciler.promoteMasterlessPartition back 0 ["m", "f"] [] ["f"] ["f"] true) == none
      && masterOf (K8sReconciler.promoteMasterlessPartitions back activationCrd ["m", "f"] [] ["f"] ["f"] true [] []) == none
      && !K8sReconciler.exMasterBackEmpty back 0 ["m", "f"] [])
  check ctx "a known-empty reading of a pod that is not live does not end the hold"
    (masterOf (K8sReconciler.promoteMasterlessPartition back 0 ["f"] [] ["f"] ["f"] true ["m"]) == none)
  check ctx "wait budget over (partition in the expired list): the unfit follower is crowned"
    (masterOf (K8sReconciler.promoteMasterlessPartitions holdState activationCrd ["f"] [] ["f"] ["f"] true [0]) == some "f"
      && masterOf (K8sReconciler.promoteMasterlessPartitions holdState activationCrd ["f"] [] ["f"] ["f"] true []) == none)
  let crdHold : K8sReconciler.FlareReconcileState :=
    { followUnfitKeys := ["m", "f"], followHoldEnabled := true, livePodKeys := ["m", "f"], dataBearingKeys := ["m", "f"] }
  check ctx "an ex-master re-seated on its partition is not reported NOT LOSS-FREE, even when probed unfit"
    (K8sReconciler.refillHoldEffects back
      (K8sReconciler.promoteMasterlessPartition back 0 ["m", "f"] [] ["m", "f"] ["f"] true) activationCrd crdHold
      |>.isEmpty)
  let logText := fun (effs : List K8sReconciler.FlareEffect) => String.intercalate "\n" (effs.filterMap fun
    | .Log m => some m
    | _ => none)
  let expiredEffs := K8sReconciler.refillHoldEffects holdState
      (K8sReconciler.promoteMasterlessPartitions holdState activationCrd ["f"] [] ["f"] ["f"] true [0]) activationCrd
      { crdHold with livePodKeys := ["f"], dataBearingKeys := ["f"], followHoldExpiredParts := [0] }
  check ctx "an unfit follower crowned after the wait is reported NOT LOSS-FREE with the EXPIRY reason (accepted-loss policy)"
    (expiredEffs.length == 1 && containsSub (logText expiredEffs) "EXPIRED" && !containsSub (logText expiredEffs) "READ empty")
  let emptyEffs := K8sReconciler.refillHoldEffects back
      (K8sReconciler.promoteMasterlessPartition back 0 ["m", "f"] [] ["f"] ["f"] true ["m"]) activationCrd
      { crdHold with livePodKeys := ["m", "f"], dataBearingKeys := ["f"], knownEmptyKeys := ["m"] }
  check ctx "an unfit follower crowned because the ex-master was READ empty is reported with THAT reason"
    (emptyEffs.length == 1 && containsSub (logText emptyEffs) "READ empty" && !containsSub (logText emptyEffs) "EXPIRED")
  check ctx "a FIT follower is crowned at once with the hold on"
    (masterOf (K8sReconciler.promoteMasterlessPartition holdState 0 ["f"] [] ["f"] [] true) == some "f")

/-- CI 37030725289 sequence: after failover the ex-master entry is
    Proxy/Down, partition -1, lastMasterOf 0; the unfit follower is Active. -/
def holdKeyed : FlareClusterState :=
  ({ nodeMap := [("m:12121", holdNode .Proxy .Down (-1) "m" 0), ("f:12121", holdNode .Slave .Active 0 "f")],
     nodeMapVersion := 5 } : FlareClusterState).rebuildPartitionMap

def checkExMasterReturn (ctx : Ctx) : IO Unit := do
  let (s1, _) := Reconciler.reconcileStep holdKeyed activationCrd (.NodeAdd "m" 12121)
  let m1 := s1.lookupNode "m:12121"
  check ctx "a failed-over ex-master re-registers as a syncing slave of its old partition, keeping lastMasterOf"
    (m1.map (fun n => (n.role == .Slave, n.state == .Prepare, n.partition, n.lastMasterOf)) == some (true, true, 0, 0))
  let s2 := K8sReconciler.assignProxiesPure s1 activationCrd ["m:12121", "f:12121"] [] [] ["f:12121"]
  check ctx "the zombie guard does not promote an excluded (unfit) Active slave"
    (masterOf s2 == none)
  let s3 := K8sReconciler.promoteMasterlessPartition s2 0 ["m:12121", "f:12121"] [] ["m:12121", "f:12121"] ["f:12121", "m:12121"] true
  check ctx "the refill re-seats the returning data-bearing ex-master, not the unfit follower"
    (masterOf s3 == some "m:12121")
  let px : FlareClusterState :=
    ({ nodeMap := [("p:12121", holdNode .Proxy .Active (-1) "p"), ("f:12121", holdNode .Slave .Active 0 "f")],
       nodeMapVersion := 5 } : FlareClusterState).rebuildPartitionMap
  let (pa, _) := Reconciler.autoAssign px activationCrd "p:12121" (holdNode .Proxy .Active (-1) "p") ["p:12121", "f:12121"] [] ["f:12121"]
  check ctx "a proxy is neither crowned over nor used to promote an unfit-only partition (left to the refill)"
    (masterOf pa == none && pa.nodeMap == px.nodeMap)
  let (pb, _) := Reconciler.autoAssign px activationCrd "p:12121" (holdNode .Proxy .Active (-1) "p") ["p:12121", "f:12121"]
  check ctx "without exclusions the zombie guard still promotes the Active slave"
    (masterOf pb == some "f:12121")
  let act : FlareClusterState :=
    { nodeMap := [("a:12121", holdNode .Master .Active 0 "a"), ("m:12121", holdNode .Slave .Prepare 0 "m" 0)], nodeMapVersion := 7 }
  let (sa, _) := Reconciler.reconcileStep act activationCrd (.NodeState "m" 12121 .Active)
  check ctx "a slave that activates under an Active master drops its lastMasterOf marker"
    ((sa.lookupNode "m:12121").map (·.lastMasterOf) == some (-1))

def nmGood : String := "version=4294967304\nh:12121 role=0 state=0 partition=0 thread=16 balance=100\ni:12121 role=1 state=0 partition=0 thread=17 balance=50"

def kindOf (d : NodeMapRecovery.Decision) : String := d.kind

def checkNodeMapRecovery (ctx : Ctx) : IO Unit := do
  let proven := NodeMapRecovery.History.provenEmpty "all pods 0/0"
  let ran := NodeMapRecovery.History.seen "lease marker"
  let unk := NodeMapRecovery.History.unknown "pod unreadable"
  check ctx "SAF-09: a valid persisted map is loaded (version and nodes kept)"
    (match NodeMapRecovery.decide (.present nmGood) ran false with
     | .load st => st.nodeMapVersion == 4294967304 && st.nodeMap.length == 2
     | _ => false)
  check ctx "SAF-09: a failed read is retried, never treated as absent (reset and approval do not override)"
    (kindOf (NodeMapRecovery.decide (.failed "timeout") proven false) == "retry"
      && kindOf (NodeMapRecovery.decide (.failed "timeout") ran true true) == "retry")
  check ctx "SAF-09: missing map + a PROVEN new cluster = first build"
    (kindOf (NodeMapRecovery.decide .notFound proven false) == "fresh")
  check ctx "SAF-09: missing map + history = halt; reset accepts a fresh start; approval does NOT"
    (kindOf (NodeMapRecovery.decide .notFound ran false) == "halt"
      && kindOf (NodeMapRecovery.decide .notFound ran true) == "fresh"
      && kindOf (NodeMapRecovery.decide .notFound ran false true) == "halt")
  check ctx "SAF-09: missing map + an UNOBSERVED past = retry, never a first build (reset does not change that)"
    (kindOf (NodeMapRecovery.decide .notFound unk false) == "retry"
      && kindOf (NodeMapRecovery.decide .notFound unk true) == "retry")
  check ctx "SAF-09: an unobserved past + first-build approval for this FlareCluster = first build"
    (kindOf (NodeMapRecovery.decide .notFound unk false true) == "fresh")
  check ctx "SAF-09: an EMPTY map is treated like a missing one"
    (kindOf (NodeMapRecovery.decide (.present "  \n") proven false) == "fresh"
      && kindOf (NodeMapRecovery.decide (.present "") ran false) == "halt"
      && kindOf (NodeMapRecovery.decide (.present "") unk false) == "retry")
  for (bad, why) in [("h:12121 role=0 state=0 partition=0", "no version line"),
                     ("version=7\nversion=8\nh:12121 role=0 state=0 partition=0", "two version lines"),
                     ("version=x\nh:12121 role=0 state=0 partition=0", "unreadable version"),
                     ("version=7\nh:12121 role=9 state=0 partition=0", "a line that does not parse"),
                     ("version=7\nh:12121 role=0 state=0 partition=0\nh:12121 role=1 state=0 partition=0", "duplicate keys"),
                     ("version=0\nh:12121 role=0 state=0 partition=0", "nodes at version 0")] do
    check ctx s!"SAF-09: an invalid map ({why}) halts, never loads partially"
      (kindOf (NodeMapRecovery.decide (.present bad) ran false) == "halt"
        && kindOf (NodeMapRecovery.decide (.present bad) proven false true) == "halt")
  check ctx "SAF-09: reset accepts discarding an invalid map"
    (kindOf (NodeMapRecovery.decide (.present "version=x") ran true) == "fresh")
  check ctx "SAF-09: only NotFound counts as absent"
    (NodeMapRecovery.classifyRead (.error "Error from server (NotFound): configmaps \"x\" not found") == .notFound
      && NodeMapRecovery.classifyRead (.error "Unable to connect to the server: dial tcp: i/o timeout") == .failed "Unable to connect to the server: dial tcp: i/o timeout"
      && NodeMapRecovery.classifyRead (.error "configmaps \"x\" not found") == .failed "configmaps \"x\" not found"
      && NodeMapRecovery.classifyRead (.ok "x") == .present "x")
  -- history: only positive proof is "new"; any gap is unknown
  let p (n : String) (r : Bool) (v i : Option Nat) : NodeMapRecovery.PodEvidence := { name := n, ready := r, nodeMapVersion := v, currItems := i }
  let isSeen := fun (h : NodeMapRecovery.History) => match h with | .seen _ => true | _ => false
  let isUnk := fun (h : NodeMapRecovery.History) => match h with | .unknown _ => true | _ => false
  let isNew := fun (h : NodeMapRecovery.History) => match h with | .provenEmpty _ => true | _ => false
  let two := [p "a" true (some 0) (some 0), p "b" true (some 0) (some 0)]
  check ctx "SAF-09 history: a Lease marker is enough (even with nothing else observed)"
    (isSeen (NodeMapRecovery.history (.ok (some "17")) false [] 0))
  check ctx "SAF-09 history: a pod with a node map version or data shows history, even if the Lease is unreadable"
    (isSeen (NodeMapRecovery.history (.error "timeout") true [p "a" false (some 9) none] 2)
      && isSeen (NodeMapRecovery.history (.ok none) true [p "a" false none (some 5)] 2))
  check ctx "SAF-09 history: proven new only with the Lease read, every expected pod read, all 0/0"
    (isNew (NodeMapRecovery.history (.ok none) true two 2))
  check ctx "SAF-09 history: an unreadable Lease is unknown, not 'no marker'"
    (isUnk (NodeMapRecovery.history (.error "forbidden") true two 2))
  check ctx "SAF-09 history: a missing stats field is unknown, not 0"
    (isUnk (NodeMapRecovery.history (.ok none) true [p "a" true (some 0) none, p "b" true (some 0) (some 0)] 2))
  check ctx "SAF-09 history: a NotReady unreadable pod is unknown (all flared restarting is not a new cluster)"
    (isUnk (NodeMapRecovery.history (.ok none) true [p "a" false none none, p "b" false none none] 2))
  check ctx "SAF-09 history: no FlareCluster and no flared pods is NOT proven new (PVCs may hold data); a missing CR with pods is unknown too"
    (isUnk (NodeMapRecovery.history (.ok none) true [] 0 true)
      && isUnk (NodeMapRecovery.history (.ok none) true [p "a" false none none] 0 true)
      && isUnk (NodeMapRecovery.history (.error "x") true [] 0 true))
  check ctx "SAF-09 history: fewer pods than the spec expects is unknown; no spec is unknown; no pod list is unknown"
    (isUnk (NodeMapRecovery.history (.ok none) true [p "a" true (some 0) (some 0)] 2)
      && isUnk (NodeMapRecovery.history (.ok none) true two 0)
      && isUnk (NodeMapRecovery.history (.ok none) false [] 2))

def checkRepairSource (ctx : Ctx) : IO Unit := do
  let ok := fun (v : Option String) => v.isNone
  let v := fun (lm le reason : String) =>
    StatsObservation.repairSourceVerdict (.known 0) (some lm) (some "L") (some le) (some "E1") (some reason)
  check ctx "SAF-08 repair source: a master holding data is a valid rebuild source"
    (ok (StatsObservation.repairSourceVerdict (.known 5)))
  check ctx "SAF-08 repair source: an unreadable item count defers"
    (!ok (StatsObservation.repairSourceVerdict .unknown (some "L") (some "L") (some "E1") (some "E1")))
  check ctx "SAF-08 repair source: empty, same lineage AND same source epoch (deleted to empty in the same history) is a valid source"
    (ok (v "L" "E1" "new"))
  check ctx "SAF-08 repair source: empty, same lineage, epoch advanced by a BULK rewrite (flush_all/truncate) is a valid source"
    (ok (v "L" "E2" "bulk"))
  check ctx "SAF-08 repair source: empty, same master_id but epoch advanced by a PROMOTION (an empty copy promoted) defers"
    (!ok (v "L" "E2" "promotion"))
  check ctx "SAF-08 repair source: empty, same master_id, epoch changed for an unknown reason (or a fresh/inherited one) defers"
    (!ok (v "L" "E2" "") && !ok (v "L" "E2" "new") && !ok (v "L" "E2" "inherited")
      && !ok (StatsObservation.repairSourceVerdict (.known 0) (some "L") (some "L") (some "E2") (some "E1")))
  check ctx "SAF-08 repair source: empty under a DIFFERENT lineage defers, even after a bulk rewrite"
    (!ok (v "L2" "E2" "bulk"))
  check ctx "SAF-08 repair source: empty with an incomparable history (lineage or epoch unreadable) defers"
    (!ok (StatsObservation.repairSourceVerdict (.known 0) none (some "L"))
      && !ok (StatsObservation.repairSourceVerdict (.known 0) (some "L") (some "L"))
      && !ok (StatsObservation.repairSourceVerdict (.known 0)))
  -- Rebuild evidence (flared rocksdb_rebuilt_from_*): the replica was last
  -- rebuilt by a clean full dump from (lineage, epoch).
  let ev := fun (lm le reason : String) (fromId fromEp : Option String) =>
    StatsObservation.repairSourceVerdict (.known 0) (some lm) (some "L") (some le) (some "E1") (some reason) fromId fromEp
  check ctx "SAF-08 repair source: empty, promoted epoch, but the replica was REBUILT BY FULL DUMP from exactly this lineage and epoch: valid (deleted to empty since)"
    (ok (ev "L" "E5" "promotion" (some "L") (some "E5")))
  check ctx "SAF-08 repair source: the same master_id but a DIFFERENT history (the evidence names an earlier epoch: an empty copy promoted since) defers"
    (!ok (ev "L" "E6" "promotion" (some "L") (some "E5")))
  check ctx "SAF-08 repair source: evidence under another lineage, missing, or partial defers"
    (!ok (ev "L" "E5" "promotion" (some "L2") (some "E5"))
      && !ok (ev "L" "E5" "promotion" none none)
      && !ok (ev "L" "E5" "promotion" none (some "E5"))
      && !ok (ev "L" "E5" "promotion" (some "L") none))
  check ctx "SAF-08 repair source: evidence never overrides a different lineage of the master itself"
    (!ok (ev "L2" "E5" "promotion" (some "L2") (some "E5")))

def checkLedgerObserve (ctx : Ctx) : IO Unit := do
  let l0 : ReplicaRepair.Ledger := {}
  -- first observation of a FRESH ledger: non-zero = possibly unrepaired request
  let (l1, d1, f1) := ReplicaRepair.observe l0 "m" [("r1", 4), ("r2", 0)] (some 7)
  check ctx "ledger: a non-zero count at the FIRST observation is a request (possibly unrepaired), not a baseline (CI 37376724850)"
    (d1 == [("r1", 4)] && f1 == ["r1"] && l1.initialized)
  let (l2, d2, f2) := ReplicaRepair.observe l1 "m" [("r1", 4), ("r2", 0)] (some 7)
  check ctx "ledger: the same cumulative value is never requested twice"
    (d2.isEmpty && f2.isEmpty)
  let (l3, d3, _) := ReplicaRepair.observe l2 "m" [("r1", 6)] (some 7)
  check ctx "ledger: an increase in the same process attributes only the difference"
    (d3 == [("r1", 2)])
  let (l4, d4, f4) := ReplicaRepair.observe l3 "m" [("r1", 9)] (some 8)
  check ctx "ledger: a RESTARTED master (new boot id) whose count climbed past the old value is attributed its WHOLE count, and its old-process counters are dropped"
    (d4 == [("r1", 9)] && f4.isEmpty && !(l4.counters.any (fun (k, _) => (k.splitOn "|").getLast? == some "7")))
  let (_, d5, _) := ReplicaRepair.observe l4 "m" [("r1", 2)] (some 8)
  check ctx "ledger: a counter that went DOWN in the same process key is a reset: its count is new drops"
    (d5 == [("r1", 2)])
  let (lb, db, fb) := ReplicaRepair.observe l0 "m" [("r1", 3)] none
  let (_, db2, _) := ReplicaRepair.observe lb "m" [("r1", 3)] none
  check ctx "ledger: without a boot id the counter comparison still works (first sighting requested once)"
    (db == [("r1", 3)] && fb == ["r1"] && db2.isEmpty)
  let (_, dz, fz) := ReplicaRepair.observe l0 "m" [("r1", 0)] (some 1)
  check ctx "ledger: a zero first sighting requests nothing"
    (dz.isEmpty && fz.isEmpty)

def checkFollowConfirm (ctx : Ctx) : IO Unit := do
  let off : FollowEvidence.Reading := { complete := true, enabled := some false }
  let on : FollowEvidence.Reading := { complete := true, enabled := some true }
  let torn : FollowEvidence.Reading := { complete := false, enabled := some true }
  let p0 := FollowEvidence.startConfirm [] ["a", "b"] true 3 10
  check ctx "follow confirm: a changed node is re-read every pass although remembered out of the mode"
    (FollowEvidence.shouldProbeWith p0 [("a", false)] "a" 11 30
      && !FollowEvidence.shouldProbe [("a", false)] "a" 11 30
      && !FollowEvidence.shouldProbeWith p0 [("c", false)] "c" 11 30)
  let (p1, e1) := FollowEvidence.stepConfirm p0 [("a", some off), ("b", some on)] 11
  check ctx "follow confirm: the OLD mode keeps it pending (no long wait); the wanted mode confirms"
    (p1.map (·.key) == ["a"] && (p1.head?.map (·.oldSeen)) == some 1
      && e1.length == 1 && (match e1 with | [.confirmed c 11] => c.key == "b" | _ => false))
  let (p2, e2) := FollowEvidence.stepConfirm p1 [("a", some torn)] 12
  check ctx "follow confirm: an unreadable (incomplete) reading is Unknown — neither confirms nor refutes"
    (p2.map (·.key) == ["a"] && (p2.head?.map (·.unknownSeen)) == some 1 && e2.isEmpty)
  let (p3, e3) := FollowEvidence.stepConfirm p2 [] 13
  check ctx "follow confirm: bounded — the budget expires (no unlimited fast poll) and the interval applies again"
    (p3.isEmpty && (match e3 with | [.expired c] => c.key == "a" | _ => false)
      && !FollowEvidence.shouldProbeWith p3 [("a", false)] "a" 14 30)
  check ctx "follow confirm: a new change restarts a pending node with the new wanted mode"
    ((FollowEvidence.startConfirm p1 ["a"] false 5 20).map (fun c => (c.key, c.want, c.left)) == [("a", false, 5)])

def checkPodRows (ctx : Ctx) : IO Unit := do
  let out := "n-0|10.0.0.1|True|n-0|svc|node-a|uid-A|2|\nn-1||False|n-1|svc||uid-B||\nn-2|10.0.0.3|True|n-2|svc|node-a|uid-C|0|2026-10-05T00:00:00Z\nbroken|row\n"
  let pods := FlareOperator.K8s.Bridge.parsePodRows "ns" out
  let find := fun (n : String) => pods.find? (·.name == n)
  check ctx "SAF-08 pod list: Ready, UID and restart count come from the SAME row"
    ((find "n-0").map (fun p => (p.ready, p.uid, p.restarts, p.terminating)) == some (true, "uid-A", some 2, false))
  check ctx "SAF-08 pod list: a Pending pod (no IP, no restart count) keeps its columns aligned; the count stays unobserved"
    ((find "n-1").map (fun p => (p.ready, p.ip, p.uid, p.restarts, p.nodeName)) == some (false, "", "uid-B", none, ""))
  check ctx "SAF-08 pod list: a deletionTimestamp marks the pod Terminating; a malformed row is dropped"
    ((find "n-2").map (·.terminating) == some true && pods.length == 3)


-- ─── E2E evidence harness (TraceMatch): ambiguous input never passes ─────

open FlareOperator.E2E.TraceMatch in
private def tdec (seq : Nat) (conn key decision reason : String) : String :=
  s!"[1][NTC][cluster.cc:1544-_trace_read] read-trace seq={seq} conn={conn} key={key} via=client decision={decision} reason={reason} target=n0:12121 partition=0 own_role=slave own_state=active map_version=7 boot_id=1"

private def tans (seq : Nat) (conn key result reason : String) : String :=
  s!"[1][NTC][cluster.cc:1564-trace_read_result] read-trace-result seq={seq} conn={conn} key={key} via=client result={result} reason={reason}"

open FlareOperator.E2E.TraceMatch in
private def checkTraceParse (ctx : Ctx) : IO Unit := do
  let all := ["init_mark_r0", "init_0", "init_1", "init_2"]
  let out := "END\r\nVALUE init_0 0 5\r\nval_0\r\nEND\r\nSERVER_ERROR read unavailable\r\nEND\r\n"
  check ctx "trace: replies parsed per key; an explicit error is err:, not a miss"
    (parseGetReplies all out == some [("init_mark_r0", "miss"), ("init_0", "=val_0"), ("init_1", "err:SERVER_ERROR read unavailable"), ("init_2", "miss")])
  check ctx "trace: fewer replies than GETs (cut off) is not observed"
    (parseGetReplies all "END\r\nVALUE init_0 0 5\r\nval_0\r\nEND\r\n" == none)
  check ctx "trace: a VALUE line without its data and END is not observed"
    (parseGetReplies ["k"] "VALUE k 0 5\r\n" == none)

open FlareOperator.E2E.TraceMatch in
private def checkTraceMatch (ctx : Ctx) : IO Unit := do
  -- round 0 on conn A; a forwarded read of the same key on the peer's
  -- connection P; round 1 REUSES port A with its own marker
  let log := String.intercalate "\n" [
    tdec 1 "10.0.0.9:40000" "init_mark_r0" "local" "slave_guard_allowed", tans 2 "10.0.0.9:40000" "init_mark_r0" "miss" "local",
    tdec 3 "10.0.0.2:5555" "init_0" "local" "master", tans 4 "10.0.0.2:5555" "init_0" "miss" "local",
    tdec 5 "10.0.0.9:40000" "init_0" "local" "slave_guard_allowed", tans 6 "10.0.0.9:40000" "init_0" "hit" "local",
    tdec 7 "10.0.0.9:40000" "init_1" "proxy" "own_slave_balance_0", tans 8 "10.0.0.9:40000" "init_1" "unavailable" "forward_failed",
    tdec 9 "10.0.0.9:40000" "init_mark_r1" "local" "slave_guard_allowed", tans 10 "10.0.0.9:40000" "init_mark_r1" "miss" "local",
    tdec 11 "10.0.0.9:40000" "init_0" "local" "slave_guard_allowed", tans 12 "10.0.0.9:40000" "init_0" "miss" "local"]
  let tr := readTraces log
  let r0 := tracesAfterMarker tr "init_mark_r0"
  let r1 := tracesAfterMarker tr "init_mark_r1"
  let t0 := (r0.lookup "init_0").getD {}
  let t1 := (r0.lookup "init_1").getD {}
  let t10 := (r1.lookup "init_0").getD {}
  check ctx "trace: the same key on another connection (a forwarded read) is not matched"
    (t0.answer.map (traceField · "seq") == some "6" && !t0.ambiguous)
  check ctx "trace: a reused port is split at its next marker (round 0 does not take round 1's line)"
    (r0.length == 2 && t10.answer.map (traceField · "seq") == some "12")
  check ctx "trace: correct value with a local hit line is ok and local"
    (classifyAnswer "=val_0" "=val_0" t0 == .ok && answeredLocally t0)
  check ctx "trace: a failed forward answered END is a MASKED MISS, not ok and not availability"
    (classifyAnswer "=val_1" "miss" t1 == .maskedMiss)
  check ctx "trace: a real local miss of a present key is a data error from the own copy"
    (classifyAnswer "=val_0" "miss" t10 == .wrongLocal)
  check ctx "trace: an explicit error reply is refused (availability)"
    (classifyAnswer "=val_0" "err:SERVER_ERROR read unavailable" t0 == .refused)
  check ctx "trace: a legitimately absent key answered miss is ok"
    (classifyAnswer "miss" "miss" t10 == .ok)
  let fwd : KeyTrace := { decision := some (tdec 1 "c" "k" "proxy" "follow_guard"), answer := some (tans 2 "c" "k" "miss" "forwarded") }
  check ctx "trace: a wrong answer after forwarding is a data error of the forwarded-to node"
    (classifyAnswer "=v" "miss" fwd == .wrongForwarded)

open FlareOperator.E2E.TraceMatch in
private def checkTraceAmbiguity (ctx : Ctx) : IO Unit := do
  let c := "10.0.0.9:40001"
  let base := [tdec 1 c "init_mark_r0" "local" "x", tdec 2 c "init_0" "local" "slave_guard_allowed"]
  let dup := readTraces (String.intercalate "\n" (base ++ [tans 3 c "init_0" "hit" "local", tans 4 c "init_0" "hit" "local"]))
  let missing := readTraces (String.intercalate "\n" base)
  let truncated := readTraces (String.intercalate "\n" (base ++ ["[1][NTC] read-trace-result seq=3 conn=" ++ c ++ " key=init_0 via=client result=hi"]))
  let markerTwice := readTraces (String.intercalate "\n" (base ++ [tans 3 c "init_0" "hit" "local", tdec 4 "10.0.0.9:40002" "init_mark_r0" "local" "x"]))
  let contra := readTraces (String.intercalate "\n" (base ++ [tans 3 c "init_0" "miss" "local"]))
  let noMarker := readTraces (String.intercalate "\n" [tdec 2 c "init_0" "local" "x", tans 3 c "init_0" "hit" "local"])
  let cls := fun (tr : List String) (a : String) => classifyAnswer "=val_0" a (((tracesAfterMarker tr "init_mark_r0").lookup "init_0").getD {})
  check ctx "trace: a duplicated answer line is ambiguous" (cls dup "=val_0" == .ambiguous)
  check ctx "trace: a missing answer line is untraced" (cls missing "=val_0" == .untraced)
  check ctx "trace: a truncated answer line is ambiguous" (cls truncated "=val_0" == .ambiguous)
  check ctx "trace: a marker seen twice makes its round ambiguous" (cls markerTwice "=val_0" == .ambiguous)
  check ctx "trace: a value reply with a 'miss' answer line contradicts: ambiguous" (cls contra "=val_0" == .ambiguous)
  check ctx "trace: without its marker no GET is matched (untraced)" (cls noMarker "=val_0" == .untraced)
  check ctx "trace: none of the ambiguous inputs classifies as ok"
    ([cls dup "=val_0", cls missing "=val_0", cls truncated "=val_0", cls markerTwice "=val_0", cls contra "=val_0", cls noMarker "=val_0"].all (· != .ok))

open FlareOperator.E2E.TraceMatch in
private def checkActivationOrder (ctx : Ctx) : IO Unit := do
  let n := fun (i : Nat) => s!"empty-source-nodes-{i}.empty-source-nodes.flare-empty-source.svc.cluster.local:12121"
  let acc := fun (v i : Nat) => s!"[NTC] node map accepted (version {v}, 3 entries); own role=slave state=prepare balance=0 partition=0; masters: 0={n i}/active"
  let dump := fun (i : Nat) => s!"[NTC] starting dump operation (master={n i}, partition=0)"
  let chk := fun (i v : Nat) => s!"[NTC] activation source check passed (attempt 1): source {n i} is the partition's master in the map read at version {v} (now {v}); copy master_id x, source epoch e"
  let act := fun (i : Nat) => s!"[NTC] node activated (attempt 1) on the copy from {n i} (map version now 9)"
  let stop := s!"[WRN] activation STOPPED before attempt 1: the partition's master is now {n 1}, not the source {n 2}"
  let old := "empty-source-nodes-2"
  check ctx "containsSubstr (linear rewrite): same answers — empty needle, start, end, absent, longer needle, multibyte text"
    (FlareOperator.E2E.Helpers.containsSubstr "abc" "" && FlareOperator.E2E.Helpers.containsSubstr "abc" "ab"
      && FlareOperator.E2E.Helpers.containsSubstr "abc" "bc" && !FlareOperator.E2E.Helpers.containsSubstr "abc" "bd"
      && !FlareOperator.E2E.Helpers.containsSubstr "ab" "abc" && FlareOperator.E2E.Helpers.containsSubstr "再構築 held by X" "held by"
      && FlareOperator.E2E.Helpers.containsSubstr "a再b" "再b" && !FlareOperator.E2E.Helpers.containsSubstr "a再b" "再c"
      && FlareOperator.E2E.Helpers.containsSubstr "aaab" "aab")
  check ctx "waitForCondition (review): a check starts only before the deadline; a hold AFTER it is late (not OK); at the deadline OK still counts; a miss at or after it is a timeout"
    (FlareOperator.E2E.Helpers.mayStartCheck 999 1000 && !FlareOperator.E2E.Helpers.mayStartCheck 1000 1000
      && FlareOperator.E2E.Helpers.waitStep true 1000 1000 == .ok
      && FlareOperator.E2E.Helpers.waitStep true 1001 1000 == .late
      && FlareOperator.E2E.Helpers.waitStep false 1000 1000 == .timeout
      && FlareOperator.E2E.Helpers.waitStep false 999 1000 == .again)
  -- R4 receiver filter (review): flared's real versioned line (cluster.cc
  -- log_notice format) and the older lines are kept; unrelated lines are not
  let realAccept := "2026-10-06T10:11:12.123456789Z [140239964415680][NTC][cluster.cc:1289-_reconstruct_node_partition_map] node map accepted (version 4294967390, 3 entries); own role=slave state=active balance=50 partition=0; masters: 0=continuous-replication-nodes-0.continuous-replication-nodes.flare-continuous-replication.svc.cluster.local:12121/active"
  check ctx "R4 receiver filter: the versioned 'node map accepted' line is kept (it was dropped before), with node_balance / node sync / role shift lines; an unrelated line is not"
    (receiverMapLine realAccept
      && receiverMapLine "[NTC] shifting node_role (node_key=x, old_role=slave, old_partition=0, new_role=master, new_partition=0)"
      && receiverMapLine "[NTC] node_balance changed 50 -> 0"
      && receiverMapLine "[NTC] read source BOUND to m (epoch e)"
      && !receiverMapLine "[NTC] storage open")
  let hold := "[NTC] activation attempt 1 held by FLARE_TEST_ACTIVATION_HOLD_FILE"
  let newPodName := "empty-source-nodes-1"
  check ctx "activation precondition (review round 3): held, then the new map accepted, then STOPPED (no held line after the acceptance is needed) — holds"
    (heldAcrossNewMap [dump 2, hold, hold, acc 415 1, stop] newPodName == none)
  check ctx "activation precondition (review round 3): the CI 37731207056 shape (activated on the old map, then accepted), no hold before the acceptance, no acceptance — NOT met"
    ((heldAcrossNewMap [dump 2, hold, chk 2 410, act 2, acc 415 1] newPodName).isSome
      && (heldAcrossNewMap [dump 2, acc 415 1, hold] newPodName).isSome
      && (heldAcrossNewMap [dump 2, hold] newPodName).isSome
      && (heldAcrossNewMap [dump 2, acc 415 1] newPodName).isSome)
  let new := "empty-source-nodes-1"
  -- CI 37438962871 test 4, shortened
  let ci := [acc 408 2, dump 2, acc 415 1, stop, dump 1, chk 1 435, act 1, acc 442 1]
  check ctx "activation: CI 37438962871 (old copy STOPPED after the new map, new copy checked then activated) passes"
    (judgeActivation ci old new).isPass
  check ctx "activation: the old copy activated AFTER accepting the new map is a bug"
    (match judgeActivation [dump 2, acc 415 1, chk 2 410, act 2] old new with | .bug _ => true | _ => false)
  check ctx "activation: the old source validated against the new map's version is a bug"
    (match judgeActivation [dump 2, acc 415 1, chk 2 415, act 2] old new with | .bug _ => true | _ => false)
  check ctx "activation: the old copy activated BEFORE accepting the new map is undecided, not a pass"
    (match judgeActivation [dump 2, chk 2 408, act 2, acc 415 1] old new with | .undecided _ => true | _ => false)
  check ctx "activation: no line accepting the new map is undetermined"
    (match judgeActivation [dump 1, chk 1 435, act 1] old new with | .undetermined _ => true | _ => false)
  check ctx "activation: activating without a passing check of that copy is a bug"
    (match judgeActivation [acc 415 1, dump 1, act 1] old new with | .bug _ => true | _ => false)
  check ctx "activation: a new dump after the last passing check, then activation, is a bug"
    (match judgeActivation [acc 415 1, dump 1, chk 1 420, dump 1, act 1] old new with | .bug _ => true | _ => false)
  check ctx "activation: no activation in the window is undetermined"
    (match judgeActivation [acc 415 1, dump 1, chk 1 420] old new with | .undetermined _ => true | _ => false)
  check ctx "activation: a passing check without a map version is undetermined"
    (match judgeActivation [acc 415 1, dump 2, "[NTC] activation source check passed (attempt 1): source " ++ n 2 ++ " is the partition's master", act 1] old new with | .undetermined _ => true | _ => false)

-- ─── copy retention §10: rebuild concurrency ──────────────────────────────

open FlareOperator.RebuildConcurrency in
private def checkRebuildConcurrency (ctx : Ctx) : IO Unit := do
  let st := fun (l : List (String × FlareNode)) => ({ nodeMap := l } : FlareClusterState).rebuildPartitionMap
  let m0 := ("m0", holdNode .Master .Active 0 "m0")
  let m1 := ("m1", holdNode .Master .Active 1 "m1")
  let before := st [m0, m1, ("a", holdNode .Proxy .Active (-1) "a"), ("b", holdNode .Proxy .Active (-1) "b"),
    ("c", holdNode .Proxy .Active (-1) "c")]
  -- the pass assigns three proxies as rebuilding slaves at once
  let after := st [m0, m1, ("a", holdNode .Slave .Prepare 0 "a"), ("b", holdNode .Slave .Prepare 0 "b"),
    ("c", holdNode .Slave .Prepare 1 "c")]
  let d := gate before after 1 1
  check ctx "rebuild concurrency: one new rebuild is admitted, the others stay Proxy (cluster limit 1)"
    (d.held.map Prod.fst == ["b", "c"]
      && ((d.state.lookupNode "a").map (·.role)) == some FlareRole.Slave
      && ((d.state.lookupNode "b").map (·.role)) == some FlareRole.Proxy
      && ((d.state.lookupNode "c").map (·.role)) == some FlareRole.Proxy
      && ((d.state.lookupPartition 0).map (·.slaves)) == some ["a"])
  let d2 := gate before after 1 2
  check ctx "rebuild concurrency: per partition 1 — a second rebuild in the same partition is held, another partition's is admitted"
    (d2.held.map Prod.fst == ["b"] && ((d2.state.lookupNode "c").map (·.role)) == some FlareRole.Slave)
  let busy := st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x"), ("a", holdNode .Proxy .Active (-1) "a")]
  let busyAfter := st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x"), ("a", holdNode .Slave .Prepare 0 "a")]
  check ctx "rebuild concurrency: a rebuild already in the map counts (also after an operator restart: the map is persisted)"
    ((gate busy busyAfter 1 1).held.map Prod.fst == ["a"])
  let idle := st [m0, m1, ("a", holdNode .Proxy .Active (-1) "a")]
  let idleAfter := st [m0, m1, ("a", holdNode .Slave .Prepare 0 "a")]
  check ctx "rebuild concurrency: a node reporting a running reconstruction in its stats counts as well"
    ((gate idle idleAfter 1 1 ["y"]).held.map Prod.fst == ["a"] && (gate idle idleAfter 1 1).held.isEmpty)
  -- R7 (review 2026-10-08): a member the MAP has Active but whose stats
  -- report a running reconstruction counts — for the cluster and for its
  -- partition — and stops new assignments and resumes
  let actBefore := st [m0, m1, ("z", holdNode .Slave .Active 1 "z"), ("a", holdNode .Proxy .Active (-1) "a")]
  let actAfter := st [m0, m1, ("z", holdNode .Slave .Active 1 "z"), ("a", holdNode .Slave .Prepare 0 "a")]
  let samePartAfter := st [m0, m1, ("z", holdNode .Slave .Active 1 "z"), ("a", holdNode .Slave .Prepare 1 "a")]
  check ctx "rebuild concurrency (R7): a map=Active member running a reconstruction holds another partition's new assignment (cluster limit 1)"
    ((gate actBefore actAfter 1 1 ["z"]).held.map Prod.fst == ["a"] && (gate actBefore actAfter 1 1).held.isEmpty)
  check ctx "rebuild concurrency (R7): ... and its own partition's new assignment even with room in the cluster (partition limit 1)"
    ((gate actBefore samePartAfter 1 2 ["z"]).held.map Prod.fst == ["a"] && (gate actBefore samePartAfter 1 2).held.isEmpty)
  let parkState := st [m0, m1, ("x", holdNode .Slave .Prepare 0 "x"), ("z", holdNode .Slave .Active 1 "z")]
  check ctx "rebuild concurrency (R7): a parked rebuild is NOT resumed while a map=Active member runs a reconstruction"
    (resumeCandidate parkState 1 1 ["x"] ["z"] == none && resumeCandidate parkState 1 1 ["x"] [] == some "x")
  -- round 2: contradictory observations — a FRESH running / unknown reading
  -- wins over an older parked one; a fresh parked-idle reading frees the slot
  let rep := fun (body : String) => some (body ++ "END\r\n")
  check ctx "rebuild concurrency (review round 3): parked=1 with in_flight / snapshot_serving MISSING is unknown (not parked-idle) — the reviewer's reply"
    (obsOfReply (some true) (rep "STAT rebuild_parked 1\r\nSTAT reconstruction_current_state running\r\n") == .unknown
      && obsOfReply (some true) (rep "STAT rebuild_parked 1\r\nSTAT rebuild_in_flight 0\r\nSTAT reconstruction_current_state running\r\n") == .unknown)
  check ctx "rebuild concurrency (review round 3): parked=1 with in_flight / serving INVALID is unknown; an explicit 0 for both is parked-idle"
    (obsOfReply (some true) (rep "STAT rebuild_parked 1\r\nSTAT rebuild_in_flight x\r\nSTAT rocksdb_snapshot_serving 0\r\n") == .unknown
      && obsOfReply (some true) (rep "STAT rebuild_parked 1\r\nSTAT rebuild_in_flight 0\r\nSTAT rocksdb_snapshot_serving 2\r\n") == .unknown
      && obsOfReply (some true) (rep "STAT rebuild_parked yes\r\nSTAT rebuild_in_flight 0\r\nSTAT rocksdb_snapshot_serving 0\r\n") == .unknown
      && obsOfReply (some true) (rep "STAT rebuild_parked 1\r\nSTAT rebuild_in_flight 0\r\nSTAT rocksdb_snapshot_serving 0\r\nSTAT reconstruction_current_state running\r\n") == .parkedIdle)
  check ctx "rebuild concurrency (review round 3): running / in flight / idle; an invalid reconstruction state is unknown; absent only when confirmed; no reply or no END is unknown"
    (obsOfReply (some true) (rep "STAT reconstruction_current_state running\r\n") == .running
      && obsOfReply (some true) (rep "STAT rebuild_parked 1\r\nSTAT rebuild_in_flight 1\r\n") == .running
      && obsOfReply (some true) (rep "STAT rebuild_in_flight 1\r\n") == .running
      && obsOfReply (some true) (rep "STAT reconstruction_current_state succeeded\r\nSTAT rebuild_parked 0\r\n") == .idle
      && obsOfReply (some true) (rep "STAT reconstruction_current_state walking\r\n") == .unknown
      && obsOfReply (some false) none == .absent
      && obsOfReply none none == .unknown
      && obsOfReply (some true) none == .unknown
      && obsOfReply (some true) (some "STAT rebuild_parked 0\r\n") == .unknown)
  check ctx "rebuild concurrency (round 2): an older parked key re-read as running or unknown is NOT subtracted; one re-read as parked-idle is; one not re-read keeps its standing"
    (reconcile ["x", "y", "w"] [("x", .running), ("y", .unknown), ("v", .parkedIdle)] == (["x", "y"], ["w", "v"]))
  let pBefore := st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x"), ("a", holdNode .Proxy .Active (-1) "a")]
  let pAfter := st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x"), ("a", holdNode .Slave .Prepare 0 "a")]
  check ctx "rebuild concurrency (round 2): a key both parked (stale) and running (fresh) holds the cluster slot; it is not resumed"
    ((gate pBefore pAfter 1 1 ["x"] ["x"]).held.map Prod.fst == ["a"]
      && (gate pBefore pAfter 1 1 [] ["x"]).held.isEmpty
      && resumeCandidate pBefore 1 1 ["x"] ["x"] == none)
  -- not gated: a rejoining member (Slave before) and a master reconstruction
  let rejoinBefore := st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x"), ("r", holdNode .Slave .Down 0 "r")]
  let rejoinAfter := st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x"), ("r", holdNode .Slave .Prepare 0 "r")]
  check ctx "rebuild concurrency: a rejoining Slave is never turned back into a Proxy (it may hold the only data)"
    ((gate rejoinBefore rejoinAfter 1 1).held.isEmpty)
  let mBefore := st [("p", holdNode .Proxy .Active (-1) "p"), ("x", holdNode .Slave .Prepare 1 "x"), m1]
  let mAfter := st [("p", holdNode .Master .Prepare 0 "p"), ("x", holdNode .Slave .Prepare 1 "x"), m1]
  check ctx "rebuild concurrency: a master reconstruction is not gated (the partition needs a master)"
    ((gate mBefore mAfter 1 1).held.isEmpty)
  -- a parked rebuild with nothing in flight gives back its CLUSTER slot only
  let parkedBefore := st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x"), ("a", holdNode .Proxy .Active (-1) "a"),
    ("b", holdNode .Proxy .Active (-1) "b")]
  let parkedAfter := st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x"), ("a", holdNode .Slave .Prepare 0 "a"),
    ("b", holdNode .Slave .Prepare 1 "b")]
  check ctx "rebuild concurrency: a parked idle rebuild frees the cluster slot (a in P0 admitted) but not its partition's (b in P1 held)"
    ((gate parkedBefore parkedAfter 1 1 [] ["x"]).held.map Prod.fst == ["b"]
      && (gate parkedBefore parkedAfter 1 1).held.map Prod.fst == ["a", "b"])
  let resumeState := st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x"), ("a", holdNode .Slave .Prepare 0 "a")]
  check ctx "rebuild concurrency: a parked rebuild is resumed only when no other rebuild runs (it takes its slot again)"
    (resumeCandidate resumeState 1 1 ["x"] == none
      && resumeCandidate resumeState 1 1 ["x", "a"] == some "x"
      && resumeCandidate (st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x")]) 1 1 ["x"] == some "x"
      && resumeCandidate (st [m0, m1, ("x", holdNode .Slave .Prepare 1 "x")]) 1 1 ["x"] ["y"] == none)

-- ─── copy retention §7: discard approvals ───────────────────────────────

open FlareOperator.CopyDiscardApproval in
private def checkCopyDiscardApproval (ctx : Ctx) : IO Unit := do
  let a : Approval := {
    name := "a1"
    clusterUID := "C"
    podUID := "P1"
    copyId := "u:2"
    requestId := "r1"
    operation := "discard-retained"
    expiresAt := "2026-10-08T00:00:00Z" }
  let pods := fun (u : String) => if u == "P1" then some "nodes-1" else none
  let now := "2026-10-07T12:00:00Z"
  check ctx "approval: a valid approval for this cluster's pod is sent to that pod"
    (CopyDiscardApproval.decide a "C" now pods == .send "nodes-1")
  check ctx "approval: another cluster's approval is left alone; a decided one is not sent again"
    (CopyDiscardApproval.decide a "OTHER" now pods == .skip && CopyDiscardApproval.decide { a with phase := "Applied" } "C" now pods == .skip
      && CopyDiscardApproval.decide { a with phase := "Unknown" } "C" now pods == .skip)
  check ctx "approval: expired, unknown operation, malformed tokens and a replaced pod are not sent"
    (CopyDiscardApproval.decide { a with expiresAt := "2026-10-07T11:59:59Z" } "C" now pods == .expire
      && (match CopyDiscardApproval.decide { a with operation := "legacy-in-place" } "C" now pods with | .refuse _ => true | _ => false)
      && (match CopyDiscardApproval.decide { a with copyId := "u:2; rm -rf /" } "C" now pods with | .refuse _ => true | _ => false)
      && (match CopyDiscardApproval.decide { a with podUID := "P2" } "C" now pods with | .refuse _ => true | _ => false)
      && (match CopyDiscardApproval.decide { a with expiresAt := "2026-10-08" } "C" now pods with | .refuse _ => true | _ => false))
  check ctx "approval: flared's answer classifies; no complete answer stays Pending (resent; flared answers a repeat from its record)"
    (CopyDiscardApproval.classify (some "applied") == ("Applied", "applied") && (CopyDiscardApproval.classify (some "already:applied")).1 == "Applied"
      && (CopyDiscardApproval.classify (some "refused:copy_changed")).1 == "Refused" && (CopyDiscardApproval.classify (some "already:refused:no_such_copy")).1 == "Refused"
      && (CopyDiscardApproval.classify (some "already:started")).1 == "Unknown" && (CopyDiscardApproval.classify (some "failed")).1 == "Failed"
      && (CopyDiscardApproval.classify none).1 == "Pending")
  check ctx "approval: the reply is read only when it ended with END"
    (CopyDiscardApproval.parseReply "STAT copy_discard_result applied\r\nEND\r\n" == some "applied"
      && CopyDiscardApproval.parseReply "STAT copy_discard_result applied\r\n" == none)

-- ─── promotion by reason (decision 2026-10-08) ────────────────────────────

private def checkPromotionEvidence (ctx : Ctx) : IO Unit := do
  let base := "STAT rocksdb_copy_identity_consistent 1\r\nSTAT rocksdb_quarantined 0\r\nSTAT rocksdb_copy_partial 0\r\nSTAT rebuild_in_flight 0\r\nSTAT rocksdb_copy_id u:1\r\nSTAT reconstruction_boot_id 7\r\nSTAT curr_items 60\r\nSTAT rocksdb_master_id M\r\nSTAT rocksdb_source_epoch 2:e\r\n"
  let reply := fun (extra : String) => some (base ++ extra ++ "END\r\n")
  let obs : PromotionEvidence.Observed := {
    mapPrepare := false, mapActive := true, podReady := true, partitionHasMaster := false
    lastMasterHistory := some ("M", "2:e") }
  let cls := fun (r : Option String) (o : PromotionEvidence.Observed) => PromotionEvidence.classify r o
  -- the PAIR: the same copy, the same history; only whether a copy is in flight differs
  check ctx "promotion by reason: a healthy copy of the last master's history, merely behind (R3 not bound) is LAGGING — a last resort may seat it"
    (cls (reply "STAT repl_read_source_eligible 0\r\nSTAT repl_read_source_state none\r\n") { obs with mapPrepare := true, mapActive := false } == .lagging)
  check ctx "promotion by reason: the same copy while a rebuild is in flight is FORBIDDEN, wait or not"
    (match cls (some ((base.replace "rebuild_in_flight 0" "rebuild_in_flight 1") ++ "STAT repl_read_source_eligible 0\r\nSTAT repl_read_source_state none\r\nEND\r\n")) { obs with mapPrepare := true, mapActive := false } with
      | .forbidden _ => true | _ => false)
  check ctx "promotion by reason: a merging dump left part-way, identity disagreement, quarantine, needs_rebuild are FORBIDDEN"
    ((match cls (some ((base.replace "rocksdb_copy_partial 0" "rocksdb_copy_partial 1") ++ "END\r\n")) obs with | .forbidden _ => true | _ => false)
      && (match cls (some ((base.replace "rocksdb_copy_identity_consistent 1" "rocksdb_copy_identity_consistent 0") ++ "END\r\n")) obs with | .forbidden _ => true | _ => false)
      && (match cls (some ((base.replace "rocksdb_quarantined 0" "rocksdb_quarantined 1") ++ "END\r\n")) obs with | .forbidden _ => true | _ => false)
      && (match cls (reply "STAT repl_read_source_state needs_rebuild\r\nSTAT repl_read_source_eligible 0\r\n") obs with | .forbidden _ => true | _ => false))
  check ctx "promotion by reason: re-validation against a PRESENT master is forbidden; the master's going does not turn it into a pass — only the RECORDED last master's history is lagging"
    ((match cls (reply "STAT repl_read_source_state revalidating\r\nSTAT repl_read_source_eligible 0\r\n") { obs with partitionHasMaster := true } with | .forbidden _ => true | _ => false)
      && cls (reply "STAT repl_read_source_state revalidating\r\nSTAT repl_read_source_eligible 0\r\n") obs == .lagging
      && (match cls (reply "STAT repl_read_source_state revalidating\r\nSTAT repl_read_source_eligible 0\r\n") { obs with lastMasterHistory := none, isLastMasterHolder := true } with | .unknown _ => true | _ => false)
      && (match cls (some ((base.replace "rocksdb_source_epoch 2:e" "rocksdb_source_epoch 9:x") ++ "STAT repl_read_source_state revalidating\r\nSTAT repl_read_source_eligible 0\r\nEND\r\n")) obs with | .unknown _ => true | _ => false))
  check ctx "promotion by reason: a parked rebuild or a running reconstruction is FORBIDDEN (the copy was never completed)"
    ((match cls (reply "STAT repl_read_source_eligible 0\r\nSTAT rebuild_parked 1\r\n") obs with | .forbidden _ => true | _ => false)
      && (match cls (reply "STAT repl_read_source_eligible 0\r\nSTAT reconstruction_current_state running\r\n") obs with | .forbidden _ => true | _ => false))
  check ctx "promotion by reason: at commit the candidate is classified AGAIN — the same process and copy turning forbidden, or eligible turning lagging, aborts"
    ((PromotionEvidence.reclassifyAllows .eligible .eligible).1
      && (PromotionEvidence.reclassifyAllows .lagging .lagging).1
      && !(PromotionEvidence.reclassifyAllows .lagging (cls (some ((base.replace "rebuild_in_flight 0" "rebuild_in_flight 1") ++ "STAT repl_read_source_eligible 0\r\nEND\r\n")) obs)).1
      && !(PromotionEvidence.reclassifyAllows .eligible (cls (reply "STAT repl_read_source_state revalidating\r\nSTAT repl_read_source_eligible 0\r\n") obs)).1
      && !(PromotionEvidence.reclassifyAllows .eligible .lagging).1)
  check ctx "promotion by reason: another history, or no record of the last master's, is UNKNOWN (held); the ex-master's own copy is known"
    ((match cls (some ((base.replace "rocksdb_source_epoch 2:e" "rocksdb_source_epoch 9:x") ++ "STAT repl_read_source_eligible 0\r\nEND\r\n")) obs with | .unknown _ => true | _ => false)
      && (match cls (reply "STAT repl_read_source_eligible 0\r\n") { obs with lastMasterHistory := none } with | .unknown _ => true | _ => false)
      && cls (reply "STAT repl_read_source_eligible 0\r\n") { obs with lastMasterHistory := none, isLastMasterHolder := true } == .lagging)
  check ctx "promotion by reason: unreadable or incomplete is UNKNOWN; a bound eligible Active copy is ELIGIBLE"
    ((match cls none obs with | .unknown _ => true | _ => false)
      && (match cls (some base) obs with | .unknown _ => true | _ => false)
      && cls (reply "STAT repl_read_source_eligible 1\r\nSTAT repl_read_source_state eligible\r\n") obs == .eligible)
  check ctx "promotion by reason: LEGACY is not unconditional — Prepare, NotReady or a running reconstruction is not legacy-promotable"
    (cls (some "STAT curr_items 60\r\nEND\r\n") { obs with mapActive := true, podReady := true } == .legacy
      && (match cls (some "STAT curr_items 60\r\nEND\r\n") { obs with mapPrepare := true, mapActive := false } with | .unknown _ => true | _ => false)
      && (match cls (some "STAT curr_items 60\r\nEND\r\n") { obs with podReady := false } with | .unknown _ => true | _ => false)
      && (match cls (some "STAT curr_items 60\r\nSTAT reconstruction_current_state running\r\nEND\r\n") obs with | .forbidden _ => true | _ => false))
  check ctx "promotion by reason: a backend without copy evidence (tch) is decided by the narrow legacy rule, not held as unknown"
    (cls (some "STAT repl_read_source_eligible 0\r\nSTAT repl_read_source_state none\r\nSTAT curr_items 60\r\nEND\r\n") { obs with lastMasterHistory := none } == .legacy
      && cls (some "STAT repl_read_source_eligible 1\r\nSTAT repl_read_source_state eligible\r\nSTAT curr_items 60\r\nEND\r\n") obs == .eligible
      && (match cls (some "STAT repl_read_source_eligible 0\r\nSTAT repl_read_source_state none\r\nSTAT curr_items 60\r\nEND\r\n") { obs with mapPrepare := true, mapActive := false } with | .unknown _ => true | _ => false)
      && (match cls (some "STAT repl_read_source_eligible 0\r\nSTAT repl_read_source_state needs_rebuild\r\nSTAT curr_items 60\r\nEND\r\n") obs with | .forbidden _ => true | _ => false))
  check ctx "promotion by reason (review 2026-10-08): the ONLY unread promotion is the first master of a partition no copy has held"
    (PromotionEvidence.firstMasterOfNewPartition true [(true, 0, -1), (true, 0, -1)] 1
      && !PromotionEvidence.firstMasterOfNewPartition true [(true, 0, -1), (true, 1, -1)] 1
      && !PromotionEvidence.firstMasterOfNewPartition true [(true, 0, -1), (false, -1, 1)] 1
      && !PromotionEvidence.firstMasterOfNewPartition false [(true, 0, -1)] 1
      && !PromotionEvidence.firstMasterOfNewPartition true [] (-1))
  check ctx "promotion by reason: an existing copy read at commit passes only as a normal promotion (not lagging, forbidden or unknown)"
    (PromotionEvidence.commitTimeAllows .eligible && PromotionEvidence.commitTimeAllows .legacy
      && !PromotionEvidence.commitTimeAllows .lagging && !PromotionEvidence.commitTimeAllows (.forbidden "x")
      && !PromotionEvidence.commitTimeAllows (.unknown "x"))
  -- review 2026-10-08 (counterexamples run with lake env lean --stdin)
  let rv := { mapPrepare := false, mapActive := true, podReady := true, partitionHasMaster := false, lastMasterHistory := none : PromotionEvidence.Observed }
  check ctx "promotion by reason (review CE-a): quarantined / part-way markers are FORBIDDEN before any legacy rule (not legacy)"
    (match cls (some "STAT rocksdb_quarantined 1\r\nSTAT rocksdb_copy_partial 1\r\nSTAT curr_items 60\r\nEND\r\n") rv with | .forbidden _ => true | _ => false)
  check ctx "promotion by reason (review CE-b): a running reconstruction is FORBIDDEN even with eligible=1 and no copy evidence (tch)"
    (match cls (some "STAT repl_read_source_eligible 1\r\nSTAT repl_read_source_state eligible\r\nSTAT reconstruction_current_state running\r\nSTAT curr_items 60\r\nEND\r\n") rv with | .forbidden _ => true | _ => false)
  check ctx "promotion by reason (review CE-c): a reported but INVALID value is UNKNOWN, not read as unreported"
    (match cls (some "STAT repl_read_source_eligible 1\r\nSTAT repl_read_source_state eligible\r\nSTAT rocksdb_copy_id copy-1\r\nSTAT rocksdb_copy_identity_consistent invalid\r\nSTAT rocksdb_copy_partial invalid\r\nSTAT curr_items 60\r\nEND\r\n") rv with | .unknown _ => true | _ => false)
  check ctx "promotion by reason: an invalid eligible / state / items / running value is UNKNOWN; a parked rebuild is FORBIDDEN on tch and legacy-shaped replies too"
    ((match cls (some "STAT repl_read_source_eligible yes\r\nSTAT curr_items 60\r\nEND\r\n") rv with | .unknown _ => true | _ => false)
      && (match cls (some "STAT repl_read_source_eligible 1\r\nSTAT repl_read_source_state bogus\r\nSTAT curr_items 60\r\nEND\r\n") rv with | .unknown _ => true | _ => false)
      && (match cls (some "STAT repl_read_source_eligible 1\r\nSTAT repl_read_source_state eligible\r\nSTAT curr_items x\r\nEND\r\n") rv with | .unknown _ => true | _ => false)
      && (match cls (some "STAT repl_read_source_eligible 1\r\nSTAT reconstruction_current_state walking\r\nSTAT curr_items 60\r\nEND\r\n") rv with | .unknown _ => true | _ => false)
      && (match cls (some "STAT repl_read_source_eligible 1\r\nSTAT repl_read_source_state eligible\r\nSTAT rebuild_parked 1\r\nSTAT curr_items 60\r\nEND\r\n") rv with | .forbidden _ => true | _ => false)
      && (match cls (some "STAT rebuild_in_flight 1\r\nSTAT curr_items 60\r\nEND\r\n") rv with | .forbidden _ => true | _ => false))
  check ctx "promotion by reason: a reply with ANY newer key is never downgraded to legacy (a lone rocksdb_copy_id is not legacy)"
    (cls (some "STAT rocksdb_copy_id c:1\r\nSTAT curr_items 60\r\nEND\r\n") rv != .legacy
      && cls (some "STAT curr_items 60\r\nEND\r\n") rv == .legacy)
  -- round 2: the real older RocksDB formats stay legacy
  let rc56 := "STAT curr_items 60\r\nSTAT rocksdb_master_id old-master-id\r\nSTAT rocksdb_repl_last_lsn 12\r\nSTAT rocksdb_latest_sequence_number 12\r\nEND\r\n"
  let rc65 := "STAT curr_items 60\r\nSTAT reconstruction_boot_id 9\r\nSTAT reconstruction_current_state succeeded\r\nSTAT rocksdb_master_id old-master-id\r\nSTAT rocksdb_source_epoch 2:e\r\nSTAT rocksdb_incarnation 1\r\nEND\r\n"
  check ctx "promotion by reason (review round 2): a v0.1.0-rc56 / rc65-shaped RocksDB reply (master id, source epoch, reconstruction state — no R3 or copy-retention key) is LEGACY when Active, Ready, idle"
    (cls (some rc56) rv == .legacy && cls (some "STAT rocksdb_master_id old-master-id\r\nSTAT curr_items 60\r\nEND\r\n") rv == .legacy
      && cls (some rc65) rv == .legacy)
  check ctx "promotion by reason (review round 2): ... but an rc65 reply with a running reconstruction is FORBIDDEN, and Prepare / NotReady stay unknown"
    ((match cls (some (rc65.replace "succeeded" "running")) rv with | .forbidden _ => true | _ => false)
      && (match cls (some rc65) { rv with mapPrepare := true, mapActive := false } with | .unknown _ => true | _ => false)
      && (match cls (some rc65) { rv with podReady := false } with | .unknown _ => true | _ => false))
  -- round 2: the restarted-promotion timeline (copy-identity 11), pure
  let vk := "n-0.c-nodes.ns.svc.cluster.local:12121"
  let opOk := s!"2026-10-08T04:31:10.865924356Z [flare-operator] PROMOTION EVIDENCE (by reason, this pass): [{vk}=eligible [boot 77]]\n2026-10-08T04:31:19.227312668Z [flare-operator] PROMOTION committed: [{vk} (pod incarnation)]\n"
  let flOk := "2026-10-08T04:31:08.269441822Z [NTC] storage open\n2026-10-08T04:31:08.271249906Z [NTC] read source BOUND to m\n2026-10-08T04:31:08.272974136Z [NTC] node activated\n"
  let tl := fun (o f b : String) => match FlareOperator.E2E.PromotionTimeline.judge o f vk b with | .ok _ => true | .error _ => false
  check ctx "timeline (review round 2): fresh eligible evidence of the current process, read after its activation and binding and before the commit, passes"
    (tl opOk flOk "77")
  check ctx "timeline (review round 2): lines WITHOUT timestamps are not accepted"
    (!tl s!"[flare-operator] PROMOTION EVIDENCE (by reason, this pass): [{vk}=eligible [boot 77]]\n[flare-operator] PROMOTION committed: [{vk}]\n" flOk "77"
      && !tl opOk "[NTC] read source BOUND to m\n[NTC] node activated\n" "77")
  check ctx "timeline (review round 2): a reading logged only AFTER the commit is not accepted"
    (!tl s!"2026-10-08T04:31:19.227312668Z [flare-operator] PROMOTION committed: [{vk}]\n2026-10-08T04:31:20.000000000Z [flare-operator] PROMOTION EVIDENCE (by reason, this pass): [{vk}=eligible [boot 77]]\n" flOk "77")
  check ctx "timeline (review round 2): an activation/binding AFTER the reading (the reading was of an earlier process), a missing activation, or another boot id is not accepted"
    (!tl opOk "2026-10-08T04:31:12.000000000Z [NTC] read source BOUND to m\n2026-10-08T04:31:12.100000000Z [NTC] node activated\n" "77"
      && !tl opOk "2026-10-08T04:31:08.271249906Z [NTC] read source BOUND to m\n" "77"
      && !tl opOk flOk "78")
  check ctx "timeline (review round 2): timestamps of different precision compare as instants, not as text"
    (FlareOperator.E2E.PromotionTimeline.parseTs "2026-10-08T04:31:08.5Z x" == some ("2026-10-08T04:31:08.500000000", "x")
      && FlareOperator.E2E.PromotionTimeline.parseTs "[flare-operator] x" == none
      && FlareOperator.E2E.PromotionTimeline.parseTs "2026-10-08T04:31:08Z x" == some ("2026-10-08T04:31:08.000000000", "x"))
  let b := PromotionEvidence.bindingOf (some "uid-1") (reply "")
  check ctx "promotion by reason: the commit refuses when the pod, the flared process or the copy changed since the reading, or it was not read"
    ((PromotionEvidence.commitAllows (some .eligible) b b).1
      && !(PromotionEvidence.commitAllows (some .eligible) b { b with podUid := some "uid-2" }).1
      && !(PromotionEvidence.commitAllows (some .eligible) b { b with bootId := some "8" }).1
      && !(PromotionEvidence.commitAllows (some .eligible) b { b with copyId := some "u:2" }).1
      && !(PromotionEvidence.commitAllows none b b).1
      && !(PromotionEvidence.commitAllows (some (.forbidden "x")) b b).1)

-- ─── R3: source eligibility (operator side) ──────────────────────────────

open FlareOperator.SourceEligibility in
private def checkSourceEligibility (ctx : Ctx) : IO Unit := do
  check ctx "R3: a slave reporting eligible=0 is withheld from promotion; eligible=1 and an explicit pre-R3 reply are not"
    (withheld [("a", .eligible 0), ("b", .eligible 1), ("c", .legacy)] == ["a"])
  check ctx "R3 (decision 2026-10-07): an unreadable or incomplete reply is WITHHELD this pass"
    (withheld [("a", .unknown), ("b", .eligible 1)] == ["a"]
      && classifyReply none == .unknown
      && classifyReply (some "STAT repl_read_source_eligible 1\r\n") == .unknown)
  check ctx "R3: a complete reply is classified by its keys; legacy only when it EXPLICITLY predates R3"
    (classifyReply (some "STAT repl_read_source_eligible 1\r\nEND\r\n") == .eligible 1
      && classifyReply (some "STAT repl_read_source_eligible 0\r\nEND\r\n") == .eligible 0
      && classifyReply (some "STAT curr_items 5\r\nEND\r\n") == .legacy
      && classifyReply (some "STAT rocksdb_copy_id u:1\r\nEND\r\n") == .unknown
      && classifyReply (some "STAT repl_read_source_state revalidating\r\nEND\r\n") == .unknown)
  check ctx "R3: a promotion is possible with a masterless partition, a missing pod, an unhealthy node or a terminating master"
    (promotionRisk true false [] [] [] && promotionRisk false true [] [] []
      && promotionRisk false false ["x"] [] [] && promotionRisk false false [] ["m"] ["m"])
  check ctx "R3: a terminating SLAVE alone or a healthy cluster is not a promotion pass"
    (!promotionRisk false false [] ["s"] ["m"] && !promotionRisk false false [] [] ["m"])
  check ctx "R3: needs_rebuild becomes a rebuild request with flared's reason; other states do not"
    (rebuildRequests [("a", some "needs_rebuild", some "history differs"), ("b", some "revalidating", none),
                      ("c", some "eligible", none), ("d", none, none), ("e", some "needs_rebuild", none)]
      == [("a", "history differs"), ("e", "the copy's source changed lineage or history")])

def run : IO UInt32 := do
  let ctx : Ctx := { failures := ← IO.mkRef [], count := ← IO.mkRef 0 }
  checkObserve ctx
  checkRequestResolve ctx
  checkGate ctx
  checkFollowOwnership ctx
  checkAdvanceHold ctx
  checkAdvanceComplete ctx
  checkJson ctx
  checkEpisodes ctx
  checkJudgeRefusals ctx
  checkJudgeAcceptance ctx
  checkStatsObservation ctx
  checkDeleteGate ctx
  checkFollowJudge ctx
  checkFollowClassify ctx
  checkFollowShaping ctx
  checkMemoryConfig ctx
  checkTopologyDelivery ctx
  checkBreakerUnavailable ctx
  checkTopologyObservation ctx
  checkTopologyMetrics ctx
  checkReactivation ctx
  checkFailoverLagHold ctx
  checkExMasterReturn ctx
  checkNodeMapRecovery ctx
  checkRepairSource ctx
  checkPodRows ctx
  checkFollowConfirm ctx
  checkLedgerObserve ctx
  checkTraceParse ctx
  checkTraceMatch ctx
  checkTraceAmbiguity ctx
  checkActivationOrder ctx
  checkSourceEligibility ctx
  checkRebuildConcurrency ctx
  checkCopyDiscardApproval ctx
  checkPromotionEvidence ctx
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
