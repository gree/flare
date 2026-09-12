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
import FlareOperator.StateMachine.ReplicaRepair

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
def firstBaseline (l : Ledger) : Option Nat := l.entries.head?.bind (·.completedBaseline)

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

def obs (v : Option Nat) (c : Option Nat) (m : Option (FlareRole × FlareState)) : Observation :=
  { reportedVersion := v, reconstructionCompleted := c, mapped := m }

def stepsOf (l : Ledger) (o : Observation) : List Step :=
  (advance l [(slaveKey, o)]).2.map (·.2)

/-- Released after confirming version 11 with completion baseline 1. -/
def lRel : Ledger := (advance lDem [(slaveKey, obs (some 11) (some 1) (some (.Proxy, .Active)))]).1

def checkAdvanceHold (ctx : Ctx) : IO Unit := do
  let old := obs (some 10) (some 1) (some (.Proxy, .Active))
  check ctx "a node still reporting the OLD version stays held"
    (stepsOf lDem old == [] && heldKeys (advance lDem [(slaveKey, old)]).1 == [slaveKey])
  let confirmed := obs (some 11) (some 1) (some (.Proxy, .Active))
  check ctx "a node reporting the demotion version is released with a completion baseline"
    (stepsOf lDem confirmed == [.released] && heldKeys lRel == []
      && firstPhase lRel == some .reseated && firstBaseline lRel == some 1)
  let unread := obs none none (some (.Proxy, .Active))
  check ctx "unreadable stats change nothing (fail closed: stay held)"
    (stepsOf lDem unread == [] && heldKeys (advance lDem [(slaveKey, unread)]).1 == [slaveKey])

def checkAdvanceComplete (ctx : Ctx) : IO Unit := do
  check ctx "Slave/Prepare is in progress, not complete"
    (stepsOf lRel (obs (some 12) (some 1) (some (.Slave, .Prepare))) == [])
  check ctx "Slave/Active with an UNMOVED reconstruction counter is NOT completion (re-announced Active)"
    (stepsOf lRel (obs (some 12) (some 1) (some (.Slave, .Active))) == [])
  let done := obs (some 12) (some 2) (some (.Slave, .Active))
  check ctx "Slave/Active with a MOVED reconstruction counter completes and removes the entry"
    (stepsOf lRel done == [.completed] && (advance lRel [(slaveKey, done)]).1.entries.isEmpty)
  check ctx "a counter that reset to zero (node restarted, reconstructed at boot) counts as moved"
    (stepsOf lRel (obs (some 12) (some 0) (some (.Slave, .Active))) == [.completed])
  check ctx "a node that became MASTER while reseated is voided"
    (stepsOf lRel (obs (some 12) (some 2) (some (.Master, .Active))) == [.voided])
  let lNoBase : Ledger := { lRel with entries := lRel.entries.map fun e => { e with completedBaseline := none } }
  let (lNB, stNB) := advance lNoBase [(slaveKey, done)]
  check ctx "with no baseline the first readable counter becomes the baseline; nothing completes yet"
    (stNB.isEmpty && firstBaseline lNB == some 2)

def lFull : Ledger :=
  let l := markDemoted (request l1 masterKey slaveKey 3) slaveKey 11
  { l with entries := l.entries.map fun e => { e with nodeKey := some slaveKey, hold := some "x" } }

def checkJson (ctx : Ctx) : IO Unit := do
  check ctx "ledger survives a JSON round trip"
    (Ledger.fromJson? lFull.toJson == some lFull)
  check ctx "an empty ledger round-trips"
    (Ledger.fromJson? empty.toJson == some empty)

def run : IO UInt32 := do
  let ctx : Ctx := { failures := ← IO.mkRef [], count := ← IO.mkRef 0 }
  checkObserve ctx
  checkRequestResolve ctx
  checkGate ctx
  checkAdvanceHold ctx
  checkAdvanceComplete ctx
  checkJson ctx
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
