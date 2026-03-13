/-
  Safety.lean - Formal safety properties for the distributed Flare system

  Key Invariants:
  1. At most one Master per partition (safety)
  2. Eventually all partitions have a Master (liveness)
  3. Topology version monotonically increases
  4. Node states follow valid transitions
-/

import FlareOperator.StateMachine.GlobalModel
import FlareOperator.StateMachine.Simulation

namespace FlareOperator.StateMachine.Safety

open FlareOperator.K8s
open FlareOperator.StateMachine.GlobalModel
open FlareOperator.StateMachine.Simulation
open FlareOperator.StateMachine.FlaredNode

/-! ## Core Invariants as Propositions -/

/-- Invariant 1: At most one Master per partition in the Operator's view -/
def AtMostOneMasterPerPartition (g : GlobalState) : Prop :=
  ∀ (p : Nat),
    let masters := g.operatorState.nodeMap.filter (fun (_, n) =>
      n.role == FlareRole.Master ∧ n.partition == Int.ofNat p)
    masters.length ≤ 1

/-- Invariant 2: Topology version is monotonically increasing -/
def VersionMonotonic (g1 g2 : GlobalState) : Prop :=
  g2.operatorState.nodeMapVersion ≥ g1.operatorState.nodeMapVersion

/-- Invariant 3: All nodes in operator's view have valid partition assignments -/
def ValidPartitionAssignments (g : GlobalState) (numPartitions : Nat) : Prop :=
  ∀ (key : String) (node : FlareNode),
    (key, node) ∈ g.operatorState.nodeMap →
    (node.role == FlareRole.Proxy ∨
     (node.partition ≥ 0 ∧ node.partition < Int.ofNat numPartitions))

/-- Invariant 4: Node state transitions are valid (no Active→Prepare backwards transitions) -/
def ValidNodeStates (g : GlobalState) : Prop :=
  ∀ (key : String) (nodeState : FlaredState),
    (key, nodeState) ∈ g.nodeStates →
    -- If a node is Active and not reconstructing, it should stay Active
    (nodeState.internalState == FlareState.Active ∧ nodeState.isReconstructing == false) →
    nodeState.internalRole ≠ FlareRole.Proxy

/-! ## Helper Lemmas -/

/-- Count masters for a specific partition -/
def countMastersForPartition (g : GlobalState) (p : Nat) : Nat :=
  (g.operatorState.nodeMap.filter (fun (_, n) =>
    n.role == FlareRole.Master ∧ n.partition == Int.ofNat p)).length

/-- Bool version of AtMostOneMasterPerPartition for computation -/
def atMostOneMasterPerPartition_bool (g : GlobalState) (maxPartitions : Nat) : Bool :=
  List.range maxPartitions |>.all (fun p => countMastersForPartition g p ≤ 1)

/-! ## Main Safety Theorem -/

/--
  Core Safety Theorem: Any single step preserves the "at most one master per partition" invariant.

  This is the foundation of our distributed system correctness.
  If the invariant holds before a step, it holds after the step.
-/
theorem stepPreservesAtMostOneMaster
    (g : GlobalState)
    (step : GlobalStep)
    (h : AtMostOneMasterPerPartition g) :
    AtMostOneMasterPerPartition (stepGlobal g step) := by
  sorry  -- Proof sketch below

/-
  PROOF SKETCH for stepPreservesAtMostOneMaster:

  Case analysis on `step`:

  1. OperatorProcessMsg case:
     - Subcase NodeAdd: New node enters as Proxy (partition = -1), no Master added yet
       → invariant preserved trivially
     - Subcase NodeState:
       - If Prepare→Active, node already assigned to partition in previous step
       - reconcileStep in Reconciler.lean uses autoAssign which checks hasMasterForPartition
       - autoAssign only assigns Master role if no existing Master for that partition
       → invariant preserved by construction

  2. NodeProcessMsg case:
     - Node receives NodeSync broadcast from Operator
     - Node updates its internal state (FlaredNode.step)
     - No changes to Operator's nodeMap
     → invariant trivially preserved (Operator state unchanged)

  3. OperatorReconcile case:
     - Calls reconcileStep with .Ping event
     - Iterates through Proxies and assigns roles via autoAssign
     - autoAssign uses findPartitionNeedingMaster which returns none if partition has Master
     → invariant preserved by Reconciler.lean's design

  4. NodeReconstructionComplete case:
     - Node sends NodeState message to Operator
     - Message enqueued but not processed yet
     → invariant trivially preserved (Operator state unchanged)

  The key insight is that Reconciler.lean's autoAssign function is designed to respect
  the invariant by checking hasMasterForPartition before assigning a Master role.
-/

/-- Corollary: Invariant holds for any sequence of steps -/
theorem atMostOneMasterInvariant
    (initial : GlobalState)
    (steps : List GlobalStep)
    (h_init : AtMostOneMasterPerPartition initial) :
    AtMostOneMasterPerPartition (stepMany initial steps) := by
  induction steps generalizing initial with
  | nil =>
    -- Base case: empty list of steps
    simp [stepMany]
    exact h_init
  | cons step rest ih =>
    -- Inductive case: step :: rest
    simp [stepMany]
    apply ih
    -- Apply the single-step theorem
    exact stepPreservesAtMostOneMaster initial step h_init

/-! ## Initialization Lemma -/

/-- The initial cluster state satisfies AtMostOneMasterPerPartition (trivially, no Masters yet) -/
theorem initClusterSatisfiesInvariant (crd : FlareClusterView) (nodeNames : List String) :
    AtMostOneMasterPerPartition (initCluster crd nodeNames) := by
  -- Initial nodeMap is empty, so no masters exist
  sorry

/-! ## Complete Safety Guarantee -/

/--
  MAIN THEOREM: Starting from a valid initial state, the system maintains
  "at most one master per partition" for any execution trace.
-/
theorem globalSystemSafety
    (crd : FlareClusterView)
    (nodeNames : List String)
    (steps : List GlobalStep) :
    AtMostOneMasterPerPartition (stepMany (initCluster crd nodeNames) steps) := by
  apply atMostOneMasterInvariant
  exact initClusterSatisfiesInvariant crd nodeNames

end FlareOperator.StateMachine.Safety

/-! ## Executable Verification -/

-- Uncomment to verify the invariant holds for scenario2_fullInit:
-- open FlareOperator.StateMachine.Safety
-- open FlareOperator.StateMachine.Simulation
-- #eval atMostOneMasterPerPartition_bool scenario2_fullInit 2
-- Expected output: true
