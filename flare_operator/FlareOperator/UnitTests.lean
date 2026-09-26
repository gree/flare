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
import FlareOperator.StateMachine.FollowEvidence
import FlareOperator.StateMachine.K8sReconciler

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
