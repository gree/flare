/-
  Simulation.lean - Executable simulation scenarios for the GlobalModel

  Demonstrates the distributed system behavior through concrete scenarios:
  1. Fresh cluster initialization (4 nodes, 2 partitions, 2 replicas)
  2. Node registration and role assignment
  3. Topology broadcast and reconstruction
  4. Verification of invariants
-/

import FlareOperator.StateMachine.GlobalModel
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.StateMachine.Simulation

open FlareOperator.K8s
open FlareOperator.StateMachine.GlobalModel

/-! ## Scenario 1: Fresh Cluster Initialization -/

/-- Test scenario: Initialize a 2-partition, 2-replica cluster (4 nodes total) -/
def scenario1_freshCluster : GlobalState :=
  let crd : FlareClusterView := {
    metadata := { name := "test-cluster", «namespace» := "flare-system" }
    spec := { partitions := 2, replicas := 2 }
  }

  let nodeNames := ["node-0", "node-1", "node-2", "node-3"]

  initCluster crd nodeNames

/-! ## Scenario 2: Full Initialization Sequence -/

/-- Execute the complete initialization: registration → assignment → broadcast → reconstruction -/
def scenario2_fullInit : GlobalState :=
  let initial := scenario1_freshCluster

  -- Step 1-4: Operator processes all NodeAdd messages
  let s1 := stepGlobal initial .OperatorProcessMsg  -- node-0 registers
  let s2 := stepGlobal s1 .OperatorProcessMsg       -- node-1 registers
  let s3 := stepGlobal s2 .OperatorProcessMsg       -- node-2 registers
  let s4 := stepGlobal s3 .OperatorProcessMsg       -- node-3 registers

  -- Step 5: Operator reconciles. This runs the production assignment
  -- function (assignProxiesPure → autoAssign), so the remaining proxies are
  -- assigned here: the P1 Master and one Slave per partition.
  let s5 := stepGlobal s4 .OperatorReconcile

  -- Drain the topology broadcasts. Every NodeAdd above ALSO enqueued a
  -- broadcast to all 4 nodes, so each node has several queued NodeSync
  -- messages and only the LAST one (from the reconcile) carries its final
  -- role. An earlier version of this trace processed exactly one message
  -- per node, which silently left every node on a stale pre-assignment
  -- topology: reconstruction never started, no Ready was ever sent, and
  -- steps "10-17" were no-ops. Process 5 per node (4 NodeAdd broadcasts +
  -- 1 reconcile broadcast); extra steps on an empty queue are no-ops.
  let drainOne (g : GlobalState) (key : String) : GlobalState :=
    stepMany g (List.replicate 5 (.NodeProcessMsg key))
  let s9 := ["node-0:11211", "node-1:11211", "node-2:11211", "node-3:11211"].foldl drainOne s5

  -- Nodes complete reconstruction (P0 Master is instant and never
  -- reconstructs; the other three were assigned in Prepare, saw the role
  -- shift in the final broadcast, and now finish: each sends `node state`
  -- (Ready for a Master, Active for a Slave) to the operator).
  let s10 := stepGlobal s9 (.NodeReconstructionComplete "node-0:11211")
  let s11 := stepGlobal s10 (.NodeReconstructionComplete "node-1:11211")
  let s12 := stepGlobal s11 (.NodeReconstructionComplete "node-2:11211")
  let s13 := stepGlobal s12 (.NodeReconstructionComplete "node-3:11211")

  -- Operator processes the Ready/Active messages: Prepare→Active completes
  -- for the P1 master and both slaves.
  let s14 := stepGlobal s13 .OperatorProcessMsg
  let s15 := stepGlobal s14 .OperatorProcessMsg
  let s16 := stepGlobal s15 .OperatorProcessMsg
  let s17 := stepGlobal s16 .OperatorProcessMsg

  s17

/-! ## Scenario 3: Master failover -/

/-- After full initialization, the P0 Master's pod dies. The operator's dead
    node detection and failover (the SAME functions the production FSM runs:
    detectDeadNodesPure → handleFailoverWithPromotion) must demote the dead
    master and promote P0's live slave — so the partition keeps exactly one
    master and its data survives on the promoted replica. -/
def scenario3_afterFailover : GlobalState :=
  stepGlobal scenario2_fullInit (.NodeDie "node-0:11211")

/-! ## Scenario 4: Zombie master resurrection -/

/-- The P0 master's flared process restarts and RE-REGISTERS (`node add`)
    while its pod never leaves the live pod list — so dead-node detection
    never fires and failover never runs. Re-registration replaces the node's
    Master entry with a fresh Proxy, leaving P0 master-less while its Active
    slave still holds the data. The next reconcile must promote THAT slave —
    not hand the master slot back to the empty, freshly-restarted zombie.
    (Without the zombie guard in `autoAssign`, the zombie became P0
    Master/Active again with an empty dataset: silent total data loss for
    the partition, reproduced by this exact trace.) -/
def scenario4_zombieResurrection : GlobalState :=
  let g := { scenario2_fullInit with
             nodeToOpQueue := [.NodeAdd "node-0" 11211] }
  let s1 := stepGlobal g .OperatorProcessMsg   -- zombie re-registers as Proxy
  stepGlobal s1 .OperatorReconcile             -- reconcile must promote the slave

/-! ## Scenario 5: Ghost slave after simultaneous partition loss -/

/-- The P0 master AND its slave die at once and the master's pod is recreated
    so fast that dead-node detection never fires (the pod list never showed a
    gap at any 5s tick). The operator state still carries a GHOST entry: the
    P0 slave (node-2) reads Slave/Active although its pod is gone. The
    re-registered master (node-0) arrives as a Proxy.

    The reconcile must NOT promote the ghost — its pod is dead; broadcasting
    it as master points the partition at nothing and starts an assignment
    churn that can end with an empty node serving (observed in CI as the
    pvc-data-survival DATA LOSS flake). With the liveness-aware guard the
    live re-registrant (which still holds the partition's data on its PVC)
    takes the master slot directly. -/
def scenario5_ghostSlave : GlobalState :=
  let g := { scenario2_fullInit with
             -- node-2's pod is gone (mid-restart); operator entry survives
             nodeStates := scenario2_fullInit.nodeStates.filter
               (fun kv => kv.1 != "node-2:11211"),
             nodeToOpQueue := [.NodeAdd "node-0" 11211] }
  let s1 := stepGlobal g .OperatorProcessMsg   -- node-0 re-registers as Proxy
  stepGlobal s1 .OperatorReconcile

/-! ## Data-preservation scenarios (spec gap closed after the truncate bugs) -/

/-- Full initialization, then clients commit writes on both Active masters
    (replicated to the partitions' Active slaves). The dataful base for
    every data-preservation assertion. -/
def scenario2_dataful : GlobalState :=
  let g := stepGlobal scenario2_fullInit (.MasterCommitsData "node-0:11211")
  stepGlobal g (.MasterCommitsData "node-3:11211")

/-- Failover on the dataful cluster: P0's master dies; the promoted replica
    must HOLD THE DATA, not merely exist. -/
def scenario3_dataful : GlobalState :=
  stepGlobal scenario2_dataful (.NodeDie "node-0:11211")

/-- Zombie resurrection on the dataful cluster. -/
def scenario4_dataful : GlobalState :=
  let g := { scenario2_dataful with nodeToOpQueue := [.NodeAdd "node-0" 11211] }
  let s1 := stepGlobal g .OperatorProcessMsg
  stepGlobal s1 .OperatorReconcile

/-- Ghost-slave scenario on the dataful cluster: the re-registered pod's
    FlaredState keeps holdsData = true — that is the PVC abstraction. -/
def scenario5_dataful : GlobalState :=
  let g := { scenario2_dataful with
             nodeStates := scenario2_dataful.nodeStates.filter
               (fun kv => kv.1 != "node-2:11211"),
             nodeToOpQueue := [.NodeAdd "node-0" 11211] }
  let s1 := stepGlobal g .OperatorProcessMsg
  stepGlobal s1 .OperatorReconcile

/-! ## Scenario 6: total-partition restart during the startup grace period -/

/-- The CI data-loss reproduction (e2e pvc-data-survival, run 29383554894):
    P0's master (node-0) AND slave (node-2) restart simultaneously and
    re-register while their stale entries are still Active — the operator's
    startup grace suppresses dead-node detection, so nothing ever cleared
    the slots. The old NodeAdd fell through to fresh registration, saw
    "all partitions full" (counting each node's own ghost) and demoted both
    returning data-bearers to Proxy; flared drops partition data on a proxy
    designation: silent total loss, curr_items 0. Now both rejoin as
    Slave/Prepare (never Proxy) and the reconcile's masterless-partition
    refill reinstates the live ex-master. -/
def scenario6_totalPartitionRestart : GlobalState :=
  let g := { scenario2_fullInit with
             nodeToOpQueue := [.NodeAdd "node-0" 11211, .NodeAdd "node-2" 11211] }
  let s1 := stepGlobal g .OperatorProcessMsg
  let s2 := stepGlobal s1 .OperatorProcessMsg
  stepGlobal s2 .OperatorReconcile

/-- Scenario 6 on the dataful cluster: both returning replicas keep
    holdsData = true across the restart — that is the PVC abstraction. -/
def scenario6_dataful : GlobalState :=
  let g := { scenario2_dataful with
             nodeToOpQueue := [.NodeAdd "node-0" 11211, .NodeAdd "node-2" 11211] }
  let s1 := stepGlobal g .OperatorProcessMsg
  let s2 := stepGlobal s1 .OperatorProcessMsg
  stepGlobal s2 .OperatorReconcile

/-- Truncate-gate probe: node-2 (holds data) is mid-restart as Proxy and
    receives a broadcast assigning it P0 Slave/Prepare while the partition's
    master node-0 is DEAD (absent from nodeStates). Reconstruction starts.
    The GATED truncate must keep node-2's data (source unreachable); the
    ungated variant — the recalled buggy flared — wipes the last copy. -/
def scenario6_base (gate : Bool) : GlobalState :=
  let g0 := scenario2_dataful
  let broadcast : List FlareNode :=
    [{ serverName := "node-2", serverPort := 11211, role := FlareRole.Slave,
       state := FlareState.Prepare, partition := 0 },
     { serverName := "node-0", serverPort := 11211, role := FlareRole.Master,
       state := FlareState.Active, partition := 0 }]
  let g := { g0 with
             gateTruncate := gate,
             -- node-0's pod is gone; node-2 restarted with its PVC: role
             -- reset to Proxy, data still on disk (holdsData true)
             nodeStates := (g0.nodeStates.filter (fun kv => kv.1 != "node-0:11211")).map
               (fun kv => if kv.1 == "node-2:11211" then
                 (kv.1, { kv.2 with internalRole := FlareRole.Proxy,
                                    internalState := FlareState.Active }) else kv),
             opToNodeQueue := [("node-2:11211", .NodeSync 999 broadcast)] }
  stepGlobal g (.NodeProcessMsg "node-2:11211")

def scenario6_gated : GlobalState := scenario6_base true
def scenario6_ungated : GlobalState := scenario6_base false

/-! ## Invariant Checks -/

/-- Check: At most one Master per partition -/
def checkOneMasterPerPartition (g : GlobalState) : Bool :=
  let nodes := g.operatorState.nodeMap
  let masters := nodes.filter (fun (_, n) => n.role == FlareRole.Master)

  -- Group masters by partition
  let p0Masters := masters.filter (fun (_, n) => n.partition == 0)
  let p1Masters := masters.filter (fun (_, n) => n.partition == 1)

  p0Masters.length <= 1 && p1Masters.length <= 1

/-- Check: All nodes have consistent view of topology version -/
def checkTopologyConsistency (g : GlobalState) : Bool :=
  let opVersion := g.operatorState.nodeMapVersion
  g.nodeStates.all (fun (_, nodeState) =>
    -- Either node hasn't received any broadcast yet, or it's at the latest version
    nodeState.localNodeMapVersion == 0 || nodeState.localNodeMapVersion == opVersion
  )

/-! ## Example Execution -/

#eval checkOneMasterPerPartition scenario1_freshCluster  -- Should be true (no masters yet)
#eval checkOneMasterPerPartition scenario2_fullInit      -- Should be true (one master per partition)

#eval scenario2_fullInit.operatorState.nodeMapVersion    -- Should be > 0
#eval scenario2_fullInit.opToNodeQueue.length            -- Should be 0 (all broadcasts delivered)
#eval scenario2_fullInit.nodeToOpQueue.length            -- Should be 0 (all messages processed)

end FlareOperator.StateMachine.Simulation
