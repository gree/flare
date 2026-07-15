/-
  VerifiedSafety.lean - Complete formal proofs WITHOUT 'sorry'

  This file contains ONLY fully proven theorems (no axioms, no sorry).
  Every theorem here is verified by Lean's kernel.
-/

import FlareOperator.StateMachine.GlobalModel
import FlareOperator.StateMachine.Simulation
import FlareOperator.StateMachine.Safety
import FlareOperator.StateMachine.K8sReconciler

namespace FlareOperator.StateMachine.VerifiedSafety

open FlareOperator.K8s
open FlareOperator.StateMachine.GlobalModel
open FlareOperator.StateMachine.Safety
open FlareOperator.StateMachine.Simulation
open FlareOperator.Reconciler
open FlareOperator.K8sReconciler (mergeClusterState demoteDuplicateMasters)

/-! ## Helper Function -/

/-- Decidable version: check invariant for a finite number of partitions -/
def checkInvariantFinite (g : GlobalState) (maxPartitions : Nat) : Bool :=
  List.range maxPartitions |>.all fun p =>
    countMastersForPartition g p ≤ 1

/-! ## VERIFIED THEOREM 1: Initial state is safe -/

/--
  FULLY PROVEN: Initial cluster has empty nodeMap, hence no masters.

  This theorem requires no axioms and is verified by computation + basic rewriting.
-/
theorem initCluster_empty_nodeMap (crd : FlareClusterView) (nodeNames : List String) :
    (initCluster crd nodeNames).operatorState.nodeMap = [] := by
  rfl

/--
  FULLY PROVEN: Initial state satisfies "at most one master per partition".

  Proof: Since nodeMap is empty, filtering for masters yields empty list.
  Empty list has length 0 ≤ 1.
-/
theorem initCluster_satisfies_invariant (crd : FlareClusterView) (nodeNames : List String) :
    AtMostOneMasterPerPartition (initCluster crd nodeNames) := by
  -- the initial nodeMap is []; every count over [] is literally zero
  intro p
  exact Nat.zero_le 1

/-! ## VERIFIED THEOREM 2: Scenario 1 (fresh cluster) is safe -/

/--
  FULLY PROVEN: Fresh cluster with 4 nodes (2 partitions) satisfies invariant.

  This is verified by symbolic execution via the `decide` tactic.
  Lean computes the state and checks the invariant holds.
-/
theorem scenario1_verified :
    checkInvariantFinite scenario1_freshCluster 2 = true := by
  decide

/-! ## VERIFIED THEOREM 3: Scenario 2 (full initialization) is safe -/

/--
  FULLY PROVEN: Complete 17-step initialization sequence maintains invariant.

  Steps executed:
  1-4:  Operator processes NodeAdd for each of 4 nodes
  5:    Operator reconciles (assigns roles)
  6-9:  Nodes receive topology broadcasts
  10-13: Nodes complete reconstruction
  14-17: Operator processes Ready/Active messages

  At EVERY step, "at most one master per partition" holds.

  This is a complete, machine-checked proof via symbolic execution.
-/
theorem scenario2_verified :
    checkInvariantFinite scenario2_fullInit 2 = true := by
  decide

/--
  NON-VACUITY: scenario 2's reconcile step really assigns roles.

  "At most one master" holds trivially on a trace that never creates
  masters, so we also prove that after full initialization BOTH partitions
  have exactly one master. This theorem fails to prove if the model's
  reconcile step degrades to a no-op again (which it silently was when it
  called `reconcileStep .Ping`).
-/
theorem scenario2_p0_has_master :
    countMastersForPartition scenario2_fullInit 0 = 1 := by
  decide

theorem scenario2_p1_has_master :
    countMastersForPartition scenario2_fullInit 1 = 1 := by
  decide

/-- Non-vacuity of the Ready chain: initialization completes with the P0
    slave ACTIVE in the operator's view. An earlier version of the trace
    processed only one broadcast per node, so reconstruction never started,
    no `node state` was ever sent, and every non-P0 node silently stayed in
    Prepare — this theorem fails to compile if that regression returns. -/
theorem scenario2_p0_slave_active :
    ((scenario2_fullInit.operatorState.nodeMap.lookup "node-2:11211").map
      (fun n => n.role == FlareRole.Slave && n.state == FlareState.Active
        && n.partition == 0)) = some true := by
  decide

/-! ## VERIFIED THEOREM 4: Master failover preserves the invariant -/

/--
  FULLY PROVEN: After the P0 Master's pod dies (scenario 3), the invariant
  still holds — using the SAME dead-node detection and promotion functions
  the production FSM runs (detectDeadNodesPure, handleFailoverWithPromotion).
-/
theorem scenario3_verified :
    checkInvariantFinite scenario3_afterFailover 2 = true := by
  decide

/-- After failover, P0 still has exactly one master (the slot is refilled,
    not left empty and not doubled). -/
theorem scenario3_p0_still_has_master :
    countMastersForPartition scenario3_afterFailover 0 = 1 := by
  decide

/-- The dead node itself is no longer a master (it was demoted). Together
    with `scenario3_p0_still_has_master` this proves the promoted node is a
    DIFFERENT, live pod — the surviving replica that still holds the
    partition's data. -/
theorem scenario3_dead_node_not_master :
    ((scenario3_afterFailover.operatorState.nodeMap.lookup "node-0:11211").map
      (fun n => n.role == FlareRole.Master)) = some false := by
  decide

/-! ## VERIFIED THEOREM 4b: Zombie master resurrection cannot steal the data -/

/--
  FULLY PROVEN: when the P0 master's flared restarts and re-registers while
  its pod never leaves the live list (so failover NEVER runs — scenario 4),
  the next reconcile promotes the partition's Active slave, which still
  holds the data. The invariant is preserved throughout.
-/
theorem scenario4_verified :
    checkInvariantFinite scenario4_zombieResurrection 2 = true := by
  decide

/-- P0 keeps exactly one master across the zombie re-registration. -/
theorem scenario4_p0_has_one_master :
    countMastersForPartition scenario4_zombieResurrection 0 = 1 := by
  decide

/-- The promoted master is the DATA-BEARING replica (node-2, the former P0
    Active slave) — not an arbitrary empty node. -/
theorem scenario4_master_is_former_slave :
    ((scenario4_zombieResurrection.operatorState.nodeMap.lookup "node-2:11211").map
      (fun n => n.role == FlareRole.Master && n.state == FlareState.Active
        && n.partition == 0)) = some true := by
  decide

/-- The zombie itself does NOT get the master slot back: it re-joins as a
    Slave in Prepare and must reconstruct from the promoted master before
    serving. (Without the zombie guard in `autoAssign`, this theorem fails:
    the zombie came back as Master/Active with an empty dataset.) -/
theorem scenario4_zombie_not_master :
    ((scenario4_zombieResurrection.operatorState.nodeMap.lookup "node-0:11211").map
      (fun n => n.role == FlareRole.Slave && n.state == FlareState.Prepare)) = some true := by
  decide

/-! ## VERIFIED THEOREM 4c: Ghost slaves are never promoted -/

/--
  FULLY PROVEN: when the P0 master and slave die together and the master's
  pod re-registers before dead-node detection ever fires (scenario 5), the
  operator still holds a GHOST Slave/Active entry for the dead slave. The
  liveness-aware guard must not promote it: the master slot goes to the
  live re-registrant instead (which, in production, still holds the
  partition's data on its PVC). This is the model of the pvc-data-survival
  DATA LOSS flake observed in CI.
-/
theorem scenario5_verified :
    checkInvariantFinite scenario5_ghostSlave 2 = true := by
  decide

/-- The live re-registrant takes the P0 master slot. -/
theorem scenario5_live_registrant_is_master :
    ((scenario5_ghostSlave.operatorState.nodeMap.lookup "node-0:11211").map
      (fun n => n.role == FlareRole.Master && n.state == FlareState.Active
        && n.partition == 0)) = some true := by
  decide

/-- The ghost (pod gone, entry still Slave/Active) is NOT promoted to
    master. Its stale entry is left for dead-node detection or its own
    re-registration to clean up. -/
theorem scenario5_ghost_not_promoted :
    ((scenario5_ghostSlave.operatorState.nodeMap.lookup "node-2:11211").map
      (fun n => n.role == FlareRole.Master)) = some false := by
  decide

/-! ## VERIFIED THEOREM 4e: total-partition restart (the CI DATA LOSS run) -/

/-- Both P0 replicas restart and re-register while their stale entries are
    still Active (startup grace, dead detection suppressed). The invariant
    holds throughout. -/
theorem scenario6_verified :
    checkInvariantFinite scenario6_totalPartitionRestart 2 = true := by
  decide

/-- The master slot is refilled — the partition does not deadlock with two
    Prepare slaves and nobody to sync from. -/
theorem scenario6_p0_has_one_master :
    countMastersForPartition scenario6_totalPartitionRestart 0 = 1 := by
  decide

/-- The refilled master is the EX-MASTER (lastMasterOf marker): the newest
    surviving copy, reinstated Master/Active so flared skips reconstruction
    and its local data keeps serving. -/
theorem scenario6_ex_master_reinstated :
    ((scenario6_totalPartitionRestart.operatorState.nodeMap.lookup "node-0:11211").map
      (fun n => n.role == FlareRole.Master && n.state == FlareState.Active
        && n.partition == 0)) = some true := by
  decide

/-- Neither returning replica was ever demoted to Proxy — the destructive
    step in the CI failure: flared drops its partition data on a proxy
    designation ("Result: Proxy | Reason: all partitions full"). -/
theorem scenario6_no_proxy_demotion :
    (scenario6_totalPartitionRestart.operatorState.nodeMap.filter
      (fun kv => kv.2.role == FlareRole.Proxy)).length = 0 := by
  decide

/-! ## VERIFIED THEOREM 4d: data preservation — the invariant we never stated

"At most one master" was fully compatible with an EMPTY master — the
truncate bugs lived exactly in that unstated dimension. These theorems
close the spec gap: every Active master holds its partition's committed
data, across failover, zombie resurrection, ghost re-registration, and —
critically — the truncate gate is proven to be what keeps it true. -/

/-- After clients commit on both masters, every Active master holds data —
    and so do the Active slaves (replication abstraction, non-vacuity). -/
theorem data_base_ok : activeMasterHoldsData scenario2_dataful = true := by decide

theorem data_slaves_replicated :
    ((findNodeState scenario2_dataful.nodeStates "node-2:11211").map (·.holdsData))
      = some true := by decide

/-- Failover: the promoted replica HOLDS THE DATA, not merely exists. -/
theorem data_failover_ok : activeMasterHoldsData scenario3_dataful = true := by decide

/-- Zombie resurrection: still no empty Active master. -/
theorem data_zombie_ok : activeMasterHoldsData scenario4_dataful = true := by decide

/-- Ghost re-registration (PVC abstraction): still no empty Active master. -/
theorem data_ghost_ok : activeMasterHoldsData scenario5_dataful = true := by decide

/-- Total-partition restart (the CI DATA LOSS run): the reinstated master
    HOLDS the data — the 100 keys survive. -/
theorem data_total_restart_ok :
    activeMasterHoldsData scenario6_dataful = true := by decide

/-- THE TRUNCATE GATE, AS A SPEC: a data-bearing node assigned a Slave
    reconstruction against a DEAD source keeps its data under the gated
    truncate (source unreachable → no truncate)... -/
theorem truncate_gate_preserves_last_copy :
    ((findNodeState scenario6_gated.nodeStates "node-2:11211").map (·.holdsData))
      = some true := by decide

/-- ...and the UNGATED variant — the recalled buggy flared — wipes the last
    copy. Re-introducing an ungated truncate makes this pair contradictory:
    the bug class is now a compile-time impossibility in the model. -/
theorem ungated_truncate_destroys_last_copy :
    ((findNodeState scenario6_ungated.nodeStates "node-2:11211").map (·.holdsData))
      = some false := by decide

/-! ## VERIFIED THEOREM 5: merge repairs the FSM-vs-TCP double-master race -/

/--
  R-1 regression model: the FSM computed `ucs` from a snapshot in which P0
  had no master and assigned pod-y; meanwhile the TCP fast path registered
  pod-x and assigned it P0 master on the live ref (`current`). A naive merge
  carries BOTH forward — two masters for P0.
-/
def r1_podX : FlareNode :=
  { serverName := "pod-x", serverPort := 11211,
    role := FlareRole.Master, state := FlareState.Active, partition := 0 }

def r1_podY : FlareNode :=
  { serverName := "pod-y", serverPort := 11211,
    role := FlareRole.Master, state := FlareState.Active, partition := 0 }

def r1_current : FlareClusterState :=
  { nodeMap := [("pod-x:11211", r1_podX)], nodeMapVersion := 2 }

def r1_ucs : FlareClusterState :=
  { nodeMap := [("pod-y:11211", r1_podY)], nodeMapVersion := 1 }

def r1_merged : FlareClusterState := mergeClusterState r1_current r1_ucs

/-- FULLY PROVEN: after the merge, P0 has exactly one master. -/
theorem r1_merge_repairs_double_master :
    (r1_merged.nodeMap.filter
      (fun kv => kv.2.role == FlareRole.Master && kv.2.partition == 0)).length = 1 := by
  decide

/-- The FSM's assignment (pod-y) is the survivor: the FSM owns role
    assignments per the merge rule. -/
theorem r1_merge_keeps_fsm_master :
    ((r1_merged.nodeMap.lookup "pod-y:11211").map
      (fun n => n.role == FlareRole.Master)) = some true := by
  decide

/-- The TCP fast path's duplicate (pod-x) is demoted back to an unassigned
    Proxy — no registration is lost, and the next reconcile re-assigns it. -/
theorem r1_merge_demotes_tcp_duplicate :
    ((r1_merged.nodeMap.lookup "pod-x:11211").map
      (fun n => n.role == FlareRole.Proxy && n.partition == -1)) = some true := by
  decide

/-! ## VERIFIED THEOREM 5b: the merge cannot resurrect ghosts -/

/--
  GHOST RESURRECTION regression (root cause of the pvc-data-survival DATA
  LOSS churn): a pod re-registers as Proxy (regEpoch 5) while the FSM's
  in-flight snapshot still says Master (regEpoch 3). The commit merge must
  keep the NEWER Proxy registration — the old rule "FSM owns roles"
  resurrected the ghost Master on every tick, locking the cluster into
  M=2 S=2 P=0 with recreated pods stuck as ghosts.
-/
def ghost_current : FlareClusterState :=
  { nodeMap := [("pod-a:11211",
      { serverName := "pod-a", serverPort := 11211, role := FlareRole.Proxy,
        state := FlareState.Active, partition := -1, regEpoch := 5 })],
    nodeMapVersion := 5 }

def ghost_ucs : FlareClusterState :=
  { nodeMap := [("pod-a:11211",
      { serverName := "pod-a", serverPort := 11211, role := FlareRole.Master,
        state := FlareState.Active, partition := 0, regEpoch := 3 })],
    nodeMapVersion := 3 }

/-- The fresh Proxy re-registration survives the stale FSM commit. -/
theorem ghost_not_resurrected :
    ((mergeClusterState ghost_current ghost_ucs).nodeMap.lookup "pod-a:11211").map
      (fun n => n.role == FlareRole.Proxy && n.regEpoch == 5) = some true := by
  decide

/-- Tie on the epoch (no re-registration happened) keeps the established
    rule: the FSM's role assignment wins. -/
theorem tie_fsm_still_owns_roles :
    ((mergeClusterState { ghost_current with nodeMap := [("pod-a:11211",
        { serverName := "pod-a", serverPort := 11211, role := FlareRole.Proxy,
          state := FlareState.Active, partition := -1, regEpoch := 3 })] }
      ghost_ucs).nodeMap.lookup "pod-a:11211").map
      (fun n => n.role == FlareRole.Master) = some true := by
  decide

/-! ## VERIFIED THEOREM 6: Checkpoints along the execution trace -/

/--
  FULLY PROVEN: After node registration (step 4), invariant holds.
-/
example :
    let crd : FlareClusterView := {
      metadata := { name := "test-cluster", «namespace» := "flare-system" }
      spec := { partitions := 2, replicas := 2 }
    }
    let initial := initCluster crd ["node-0", "node-1", "node-2", "node-3"]
    let s1 := stepGlobal initial .OperatorProcessMsg
    let s2 := stepGlobal s1 .OperatorProcessMsg
    let s3 := stepGlobal s2 .OperatorProcessMsg
    let s4 := stepGlobal s3 .OperatorProcessMsg
    checkInvariantFinite s4 2 = true := by
  decide

/--
  FULLY PROVEN: After reconciliation (step 5), invariant holds.
-/
example :
    let crd : FlareClusterView := {
      metadata := { name := "test-cluster", «namespace» := "flare-system" }
      spec := { partitions := 2, replicas := 2 }
    }
    let initial := initCluster crd ["node-0", "node-1", "node-2", "node-3"]
    let s4 := stepMany initial [
      .OperatorProcessMsg, .OperatorProcessMsg,
      .OperatorProcessMsg, .OperatorProcessMsg
    ]
    let s5 := stepGlobal s4 .OperatorReconcile
    checkInvariantFinite s5 2 = true := by
  decide

/-! ## Summary -/

/-
  WHAT WE HAVE PROVEN (no sorry in THIS file; verified by Lean's kernel):

  ✓ Initial cluster state satisfies AtMostOneMasterPerPartition
  ✓ Fresh 4-node cluster satisfies invariant
  ✓ Complete 17-step initialization maintains invariant, AND is non-vacuous:
    both partitions end with exactly one master (scenario2_p{0,1}_has_master)
  ✓ Master failover (P0 master pod dies) preserves the invariant, refills
    the master slot, and the promoted node is a different live pod — using
    the same detectDeadNodesPure / handleFailoverWithPromotion functions the
    production FSM executes
  ✓ Zombie-master resurrection (scenario 4): a master whose flared restarts
    and re-registers while failover never fires CANNOT reclaim the master
    slot; the data-bearing Active slave is promoted instead
  ✓ mergeClusterState repairs the FSM-vs-TCP double-master race (R-1)
  ✓ GENERAL (not scenario-bound): demoteDuplicateMasters_atMostOne and
    mergeClusterState_atMostOneMaster in K8sReconciler.lean prove by
    induction — for ARBITRARY inputs — that the committed node map never
    holds two Masters for one partition
  ✓ Intermediate checkpoints maintain invariant

  METHOD: Computational reflection via `decide` tactic
  - Lean symbolically executes the state machine and reduces to `true`

  HONEST LIMITS (do not overstate these results):
  - The scenario theorems here are CONCRETE traces; the GENERAL inductive
    proof over arbitrary states and arbitrary step sequences now exists,
    sorry-free, in GeneralSafety.lean (`stepGlobal_cle`,
    `stepGlobal_preserves_atMostOne`, `stepMany_preserves_atMostOne`) and
    discharges Safety.lean's `stepPreservesAtMostOneMaster`.
  - The model shares the pure functions (reconcileStep, autoAssign,
    assignProxiesPure, detectDeadNodesPure, handleFailoverWithPromotion,
    mergeClusterState) with the production operator, but the IO layer
    (kubectl, TCP server threads, ConfigMap persistence) and true
    concurrency are NOT modeled; the model is sequential.
  - Value of these theorems: regression tests that fail compilation if the
    shared pure logic breaks the invariant on these paths, plus formal
    documentation of intended behavior.
-/

end FlareOperator.StateMachine.VerifiedSafety

/-! ## Verification Certificate -/

open FlareOperator.StateMachine.VerifiedSafety

-- Verify theorem types (no axioms used)
#check scenario2_verified
-- #print scenario2_verified  -- Uncomment to see full proof term
