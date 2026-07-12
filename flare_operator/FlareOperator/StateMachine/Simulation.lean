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

  -- Step 6-9: Nodes receive topology broadcasts
  let s6 := stepGlobal s5 (.NodeProcessMsg "node-0:11211")
  let s7 := stepGlobal s6 (.NodeProcessMsg "node-1:11211")
  let s8 := stepGlobal s7 (.NodeProcessMsg "node-2:11211")
  let s9 := stepGlobal s8 (.NodeProcessMsg "node-3:11211")

  -- Step 10-13: Nodes complete reconstruction (P0 Master is instant; the
  -- other roles were assigned in Prepare and reconstruct before Active)
  let s10 := stepGlobal s9 (.NodeReconstructionComplete "node-0:11211")
  let s11 := stepGlobal s10 (.NodeReconstructionComplete "node-1:11211")
  let s12 := stepGlobal s11 (.NodeReconstructionComplete "node-2:11211")
  let s13 := stepGlobal s12 (.NodeReconstructionComplete "node-3:11211")

  -- Step 14-17: Operator processes Ready/Active messages
  let s14 := stepGlobal s13 .OperatorProcessMsg  -- node-0 Ready
  let s15 := stepGlobal s14 .OperatorProcessMsg  -- node-1 Ready
  let s16 := stepGlobal s15 .OperatorProcessMsg  -- node-2 Ready
  let s17 := stepGlobal s16 .OperatorProcessMsg  -- node-3 Ready

  s17

/-! ## Scenario 3: Master failover -/

/-- After full initialization, the P0 Master's pod dies. The operator's dead
    node detection and failover (the SAME functions the production FSM runs:
    detectDeadNodesPure → handleFailoverWithPromotion) must demote the dead
    master and promote P0's live slave — so the partition keeps exactly one
    master and its data survives on the promoted replica. -/
def scenario3_afterFailover : GlobalState :=
  stepGlobal scenario2_fullInit (.NodeDie "node-0:11211")

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
