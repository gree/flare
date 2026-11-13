/-
  SafetyProofs.lean - Complete formal proofs for distributed system safety

  Proves the core invariant "at most one master per partition" without axioms (no 'sorry').
-/

import FlareOperator.StateMachine.GlobalModel
import FlareOperator.StateMachine.Simulation
import FlareOperator.StateMachine.Safety

namespace FlareOperator.StateMachine.SafetyProofs

open FlareOperator.K8s
open FlareOperator.StateMachine.GlobalModel
open FlareOperator.StateMachine.Safety
open FlareOperator.StateMachine.Simulation
open FlareOperator.Reconciler

/-! ## Helper Lemmas -/

/-- Empty list filtered by any predicate is empty -/
theorem filter_empty {α : Type _} (p : α → Bool) :
    ([] : List α).filter p = [] := by rfl

/-- If masters list has length ≤ 1, then after any filter it still has length ≤ 1 -/
theorem filter_preserves_length_le_one {α : Type _} (l : List α) (p : α → Bool)
    (h : l.length ≤ 1) :
    (l.filter p).length ≤ 1 := by
  -- Filter can only make the list smaller or keep it the same size
  cases l with
  | nil => simp [List.filter]
  | cons x xs =>
    cases xs with
    | nil => simp [List.filter]; split <;> simp
    | cons y ys => simp at h  -- length ≥ 2, contradicts h

/-- Initial cluster has empty nodeMap -/
theorem initCluster_nodeMap_empty (crd : FlareClusterView) (nodeNames : List String) :
    (initCluster crd nodeNames).operatorState.nodeMap = [] := by
  simp [initCluster, FlareClusterState.default]

/-! ## Proof 1: Initial state satisfies invariant -/

/--
  The initial cluster state satisfies AtMostOneMasterPerPartition.
  Proof: The operator starts with an empty nodeMap, so no masters exist.
-/
theorem initClusterSatisfiesInvariant_v2 (crd : FlareClusterView) (nodeNames : List String) :
    AtMostOneMasterPerPartition (initCluster crd nodeNames) := by
  intro p
  -- initial nodeMap is []; the count over [] is literally 0
  exact Nat.zero_le 1

/-! ## Proof 2: Single step preserves invariant -/

/-- Registering a node as Proxy never increases any partition's master
    count. (The historical version of this lemma claimed EQUALITY, which is
    false: a re-registering node whose old entry was a Master strictly
    decreases the count — that is exactly the zombie-master scenario.) -/
theorem addNode_proxy_le (state : FlareClusterState) (key : String)
    (node : FlareNode) (p : Int)
    (h_proxy : node.role = FlareRole.Proxy) :
    FlareOperator.K8sReconciler.countMastersFor p (state.addNode key node).nodeMap
      ≤ FlareOperator.K8sReconciler.countMastersFor p state.nodeMap := by
  apply GeneralSafety.count_addNode_nonmaster
  simp [GeneralSafety.isM, h_proxy, show (FlareRole.Proxy == FlareRole.Master) = false from rfl]

/--
  Core Safety Theorem (simplified version):
  If at most one master per partition holds, and we process a NodeAdd event
  (which creates a Proxy), the invariant is preserved.
-/
theorem nodeAdd_preserves_invariant
    (g : GlobalState)
    (serverName : String)
    (serverPort : Nat)
    (h : AtMostOneMasterPerPartition g) :
    let msg := NodeToOperatorMsg.NodeAdd serverName serverPort
    let g' := stepGlobal g .OperatorProcessMsg
    -- If the next message is NodeAdd, invariant holds
    (g.nodeToOpQueue.head? = some msg) →
    AtMostOneMasterPerPartition g' := by
  intro _msg _g' _hmsg
  exact stepPreservesAtMostOneMaster g .OperatorProcessMsg h

/-! ## Simplified Invariant for Computational Verification -/

/--
  Decidable version: check invariant for a finite number of partitions.
  This can be evaluated and proven by `decide` tactic.
-/
def checkInvariantFinite (g : GlobalState) (maxPartitions : Nat) : Bool :=
  List.range maxPartitions |>.all fun p =>
    countMastersForPartition g p ≤ 1

/--
  For the specific scenario with 2 partitions, we can verify by computation.
-/
theorem scenario1_satisfies_invariant :
    checkInvariantFinite scenario1_freshCluster 2 = true := by
  decide

theorem scenario2_satisfies_invariant :
    checkInvariantFinite scenario2_fullInit 2 = true := by
  decide

/-! ## Unbounded trace safety (formerly a bounded, sorry-backed statement) -/

/--
  For ANY execution trace of ANY length from ANY initial cluster, the
  finite invariant check passes — a direct corollary of the general
  inductive proof (GeneralSafety.lean via Safety.globalSystemSafety).
  The previous version of this theorem was bounded to 20 steps and ended
  in `sorry`; no bound is needed anymore.
-/
theorem trace_safety (crd : FlareClusterView) (nodeNames : List String)
    (steps : List GlobalStep) (maxPartitions : Nat) :
    checkInvariantFinite (stepMany (initCluster crd nodeNames) steps) maxPartitions = true := by
  have hs := globalSystemSafety crd nodeNames steps
  unfold checkInvariantFinite
  rw [List.all_eq_true]
  intro p _
  exact decide_eq_true (hs p)

/-! ## Main Result: Computational Verification -/

/--
  VERIFIED THEOREM: The concrete scenario2_fullInit execution
  maintains at most one master per partition.

  This is a complete, sorry-free proof for the specific execution trace.
-/
example : atMostOneMasterPerPartition_bool scenario2_fullInit 2 = true := by
  decide

/--
  VERIFIED THEOREM: Initial fresh cluster has no duplicate masters.
-/
example : atMostOneMasterPerPartition_bool scenario1_freshCluster 2 = true := by
  decide

/-! ## Documentation of Proof Strategy -/

/-
  PROOF STRATEGY SUMMARY:

  We have proven two types of theorems:

  1. **Computational Verification (100% proven, no sorry)**:
     - `scenario1_satisfies_invariant`: Initial state is safe ✓
     - `scenario2_satisfies_invariant`: Full initialization trace is safe ✓
     - These are proven by `decide` tactic, which evaluates the computation.

  2. **General Inductive Proof (COMPLETE, sorry-free since GeneralSafety.lean)**:
     - `stepPreservesAtMostOneMaster`: safety for arbitrary steps — proven
     - `globalSystemSafety`: safety for arbitrary traces — proven
     - `trace_safety` above: the executable-check version, any length.

  WHY IS COMPUTATIONAL VERIFICATION VALUABLE?

  The `decide` tactic provides a COMPLETE PROOF for specific scenarios by:
  - Executing the state machine symbolically
  - Checking the invariant at each step
  - Validating by Lean's kernel (no axioms)

  This gives us:
  - 100% confidence for tested scenarios (no bugs can hide)
  - Executable specification that doubles as test oracle
  - Foundation for property-based testing (QuickCheck style)

  There are no remaining `sorry` statements in the safety development:
  the general case analysis lives in GeneralSafety.lean as the uniform
  bound `stepGlobal_cle` (count ≤ max old 1 per partition, per step).
-/

end FlareOperator.StateMachine.SafetyProofs
