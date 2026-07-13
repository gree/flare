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
import FlareOperator.StateMachine.GeneralSafety

namespace FlareOperator.StateMachine.Safety

open FlareOperator.K8s
open FlareOperator.StateMachine.GlobalModel
open FlareOperator.StateMachine.Simulation
open FlareOperator.StateMachine.FlaredNode

/-! ## Core Invariants as Propositions -/

/-- Invariant 1: At most one Master per partition in the Operator's view.
    Counted via `K8sReconciler.countMastersFor` — the SAME function the
    general preservation proof (GeneralSafety.lean) and the merge-repair
    theorems are stated against, so all safety results share one counting
    definition. -/
def AtMostOneMasterPerPartition (g : GlobalState) : Prop :=
  ∀ (p : Nat),
    FlareOperator.K8sReconciler.countMastersFor (Int.ofNat p) g.operatorState.nodeMap ≤ 1

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
  FlareOperator.K8sReconciler.countMastersFor (Int.ofNat p) g.operatorState.nodeMap

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
  intro p
  have hc := GeneralSafety.stepGlobal_cle g step (Int.ofNat p)
  have hp := h p
  omega

/-
  The proof lives in GeneralSafety.lean: every state-mutating operation
  (autoAssign, assignProxiesPure, reconcileStep, handleFailoverWithPromotion)
  satisfies the hypothesis-free bound `stepGlobal_cle` —
  count p (new) ≤ max (count p old) 1 — from which preservation follows for
  every partition. The former proof sketch that lived here is superseded.
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
  -- the initial nodeMap is empty, so every count is literally zero
  intro p
  exact Nat.zero_le 1

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
