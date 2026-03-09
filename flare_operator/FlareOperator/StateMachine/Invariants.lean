/-
  Invariants.lean - Safety invariants for the Flare operator
  Following Gungnir/StateMachine/Invariants.lean pattern

  Architecture (gungnir pattern):
  1. Define `validFlareTransition` as a conjunction of properties on (s, s')
  2. Prove invariants by extraction from the conjunction (trivial)
  3. Implementation-specific lemmas proved directly against reconcileStep
  4. `reconcileStep_valid` bridges implementation to transition relation

  Key invariants:
  1. atMostOneMasterPerPartition: No two nodes are masters of the same partition
  2. proxiesUnassigned: Proxy nodes always have partition = -1
  3. versionMonotonic: nodeMapVersion never decreases
  4. mutation_never_changes_state: Manual mutations never change state
  5. Read-only events preserve state (8 theorems)
  6. nodeRemove_rejected: NodeRemove returns SERVER_ERROR
  7. reconcile_always_responds: Liveness
  8. nodeAdd_progress: NodeAdd increments version (liveness)
  9. parseFlareCommand_total: Parser totality
  10. event_exhaustive: All event constructors handled
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol
import FlareOperator.StateMachine.Reconciler

namespace FlareOperator.Invariants

open FlareOperator.K8s
open FlareOperator.Flare
open FlareOperator.Reconciler

-- ===========================================================================
-- Helper Lemmas: addNode / setPartition structure
-- ===========================================================================

theorem addNode_version (state : FlareClusterState) (key : String) (node : FlareNode) :
    (state.addNode key node).nodeMapVersion = state.nodeMapVersion + 1 := by
  unfold FlareClusterState.addNode; rfl

theorem setPartition_version (state : FlareClusterState) (idx : Nat) (p : FlarePartition) :
    (state.setPartition idx p).nodeMapVersion = state.nodeMapVersion := by
  unfold FlareClusterState.setPartition; rfl

theorem setPartition_nodeMap (state : FlareClusterState) (idx : Nat) (p : FlarePartition) :
    (state.setPartition idx p).nodeMap = state.nodeMap := by
  unfold FlareClusterState.setPartition; rfl

theorem addNode_nodeMap (state : FlareClusterState) (key : String) (node : FlareNode) :
    (state.addNode key node).nodeMap = (key, node) :: state.nodeMap.filter (·.1 != key) := by
  unfold FlareClusterState.addNode; rfl

theorem autoAssign_version (state : FlareClusterState) (crd : FlareClusterView)
    (key : String) (node : FlareNode) :
    (autoAssign state crd key node).1.nodeMapVersion = state.nodeMapVersion + 1 := by
  unfold autoAssign
  simp only []
  split
  · simp only [setPartition_version, addNode_version]
  · split
    · simp only [setPartition_version, addNode_version]
    · simp only [addNode_version]

-- ===========================================================================
-- Safety Invariant Definitions
-- ===========================================================================

/-- At most one master per partition (split-brain prevention). -/
def atMostOneMasterPerPartition (state : FlareClusterState) : Prop :=
  ∀ (k1 k2 : String) (n1 n2 : FlareNode),
    (k1, n1) ∈ state.nodeMap →
    (k2, n2) ∈ state.nodeMap →
    n1.role = FlareRole.Master →
    n2.role = FlareRole.Master →
    n1.partition = n2.partition →
    k1 = k2

/-- All proxy nodes have partition = -1. -/
def proxiesUnassigned (state : FlareClusterState) : Prop :=
  ∀ (entry : String × FlareNode),
    entry ∈ state.nodeMap →
    entry.2.role = FlareRole.Proxy →
    entry.2.partition = -1

/-- nodeMapVersion never decreases. -/
def versionMonotonic (state state' : FlareClusterState) : Prop :=
  state'.nodeMapVersion ≥ state.nodeMapVersion

-- ===========================================================================
-- Next-State Relation (gungnir pattern: conjunction of properties)
-- ===========================================================================

/-- Valid flare transition: encodes safety properties as a conjunction.
    Following gungnir's `validTransition` (Invariants.lean:89-109).
    Properties are stated directly on s', making invariant proofs trivial. -/
def validFlareTransition (s s' : FlareClusterState) : Prop :=
  -- 1. At most one master per partition in s'
  atMostOneMasterPerPartition s' ∧
  -- 2. Proxies have partition = -1 in s'
  proxiesUnassigned s' ∧
  -- 3. Version monotonicity
  s'.nodeMapVersion ≥ s.nodeMapVersion

-- ===========================================================================
-- Safety Invariants by Extraction (gungnir pattern — trivial proofs)
-- ===========================================================================

/-- atMostOneMasterPerPartition is an inductive invariant.
    Proof: extract from conjunction (gungnir pattern). -/
theorem atMostOneMasterPerPartition_invariant :
    ∀ (s s' : FlareClusterState),
      atMostOneMasterPerPartition s →
      validFlareTransition s s' →
      atMostOneMasterPerPartition s' := by
  intro s s' _ hNext
  exact hNext.1

/-- proxiesUnassigned is an inductive invariant.
    Proof: extract from conjunction (gungnir pattern). -/
theorem proxiesUnassigned_invariant :
    ∀ (s s' : FlareClusterState),
      proxiesUnassigned s →
      validFlareTransition s s' →
      proxiesUnassigned s' := by
  intro s s' _ hNext
  exact hNext.2.1

/-- versionMonotonic holds under valid transitions.
    Proof: extract from conjunction (gungnir pattern). -/
theorem versionMonotonic_invariant :
    ∀ (s s' : FlareClusterState),
      validFlareTransition s s' →
      versionMonotonic s s' := by
  intro s s' hNext
  exact hNext.2.2

-- ===========================================================================
-- Init state satisfies all invariants
-- ===========================================================================

theorem atMostOneMasterPerPartition_init :
    atMostOneMasterPerPartition FlareClusterState.default := by
  intro k1 k2 n1 n2 h1 _ _ _ _
  simp [FlareClusterState.default] at h1

theorem proxiesUnassigned_init :
    proxiesUnassigned FlareClusterState.default := by
  intro entry h; simp [FlareClusterState.default] at h

-- ===========================================================================
-- Implementation-specific lemmas (proved directly against reconcileStep)
-- ===========================================================================

/-- MutationAttempt never changes state. -/
theorem mutation_never_changes_state :
    ∀ (state : FlareClusterState) (crd : FlareClusterView) (raw : String),
      (reconcileStep state crd (FlareEvent.MutationAttempt raw)).1 = state := by
  intro state crd raw; simp [reconcileStep]

/-- NodeRemove always returns SERVER_ERROR. -/
theorem nodeRemove_rejected (s : FlareClusterState) (c : FlareClusterView)
    (name : String) (port : Nat) :
    (reconcileStep s c (.NodeRemove name port)).2 =
      .ServerError "node removal is managed by Kubernetes" := by
  simp [reconcileStep]

-- Read-only events preserve state (8 theorems)
theorem ping_preserves (s : FlareClusterState) (c : FlareClusterView) :
    (reconcileStep s c .Ping).1 = s := by simp [reconcileStep]
theorem meta_preserves (s : FlareClusterState) (c : FlareClusterView) :
    (reconcileStep s c .Meta).1 = s := by simp [reconcileStep]
theorem stats_preserves (s : FlareClusterState) (c : FlareClusterView) :
    (reconcileStep s c .Stats).1 = s := by simp [reconcileStep]
theorem version_preserves (s : FlareClusterState) (c : FlareClusterView) :
    (reconcileStep s c .Version).1 = s := by simp [reconcileStep]
theorem quit_preserves (s : FlareClusterState) (c : FlareClusterView) :
    (reconcileStep s c .Quit).1 = s := by simp [reconcileStep]
theorem nodeSync_preserves (s : FlareClusterState) (c : FlareClusterView) (v : Option Nat) :
    (reconcileStep s c (.NodeSync v)).1 = s := by simp [reconcileStep]
theorem nodeRemove_preserves (s : FlareClusterState) (c : FlareClusterView) (n : String) (p : Nat) :
    (reconcileStep s c (.NodeRemove n p)).1 = s := by simp [reconcileStep]
theorem parseError_preserves (s : FlareClusterState) (c : FlareClusterView) (r : String) :
    (reconcileStep s c (.ParseError r)).1 = s := by simp [reconcileStep]

-- ===========================================================================
-- Liveness properties
-- ===========================================================================

/-- reconcileStep always produces a response (liveness by totality). -/
theorem reconcile_always_responds (s : FlareClusterState) (c : FlareClusterView)
    (e : FlareEvent) :
    ∃ (s' : FlareClusterState) (r : FlareResponse),
      reconcileStep s c e = (s', r) := by
  exact ⟨_, _, rfl⟩

/-- NodeAdd strictly increments nodeMapVersion (forward progress). -/
theorem nodeAdd_progress (s : FlareClusterState) (c : FlareClusterView)
    (name : String) (port : Nat) :
    (reconcileStep s c (.NodeAdd name port)).1.nodeMapVersion
      = s.nodeMapVersion + 1 := by
  unfold reconcileStep; simp only []
  exact autoAssign_version s c (FlareClusterState.toNodeKey name port)
    { serverName := name, serverPort := port,
      role := FlareRole.Proxy, state := FlareState.Active,
      partition := -1, balance := 100, threadType := 16 }

/-- Parser totality. -/
theorem parseFlareCommand_total (line : String) :
    ∃ (e : FlareEvent), parseFlareCommand line = e := by
  exact ⟨parseFlareCommand line, rfl⟩

/-- Event exhaustiveness. -/
theorem event_exhaustive (event : FlareEvent) :
    match event with
    | .Ping => True | .Meta => True | .Stats => True | .Version => True
    | .Quit => True | .NodeAdd _ _ => True | .NodeSync _ => True
    | .NodeRemove _ _ => True | .MutationAttempt _ => True
    | .ParseError _ => True := by
  cases event <;> trivial

-- ===========================================================================
-- reconcileStep satisfies validFlareTransition (metric reduction)
--
-- Following gungnir pattern: this bridges the implementation to the
-- transition relation. Uses metric reduction: the "metric" is
-- masterCountForPartition (number of masters per partition),
-- which stays ≤ 1 across transitions.
-- ===========================================================================

/-- Metric: count of masters for a given partition. -/
def masterCountForPartition (state : FlareClusterState) (pIdx : Int) : Nat :=
  (state.nodeMap.filter (fun e => e.2.role == FlareRole.Master && e.2.partition == pIdx)).length

/-- proxiesUnassigned is preserved by reconcileStep (direct proof). -/
theorem proxiesUnassigned_step
    (state : FlareClusterState) (crd : FlareClusterView) (event : FlareEvent)
    (h_inv : proxiesUnassigned state) :
    proxiesUnassigned (reconcileStep state crd event).1 := by
  cases event with
  | Ping => exact h_inv
  | Meta => exact h_inv
  | Stats => exact h_inv
  | Version => exact h_inv
  | Quit => exact h_inv
  | NodeSync _ => exact h_inv
  | NodeRemove _ _ => exact h_inv
  | MutationAttempt _ => exact h_inv
  | ParseError _ => exact h_inv
  | NodeAdd serverName serverPort =>
    unfold proxiesUnassigned reconcileStep
    simp only []
    intro ⟨k, n⟩ h_mem h_proxy
    unfold autoAssign at h_mem
    simp only [] at h_mem
    split at h_mem
    · -- Master branch: new node has role = Master ≠ Proxy
      dsimp at h_mem
      rw [setPartition_nodeMap, addNode_nodeMap, List.mem_cons] at h_mem
      cases h_mem with
      | inl h_eq =>
        exfalso
        have := congrArg (FlareNode.role ∘ Prod.snd) h_eq
        simp at this; rw [this] at h_proxy; exact absurd h_proxy (by decide)
      | inr h_old =>
        rw [List.mem_filter] at h_old
        exact h_inv (k, n) h_old.1 h_proxy
    · split at h_mem
      · -- Slave branch
        dsimp at h_mem
        rw [setPartition_nodeMap, addNode_nodeMap, List.mem_cons] at h_mem
        cases h_mem with
        | inl h_eq =>
          exfalso
          have := congrArg (FlareNode.role ∘ Prod.snd) h_eq
          simp at this; rw [this] at h_proxy; exact absurd h_proxy (by decide)
        | inr h_old =>
          rw [List.mem_filter] at h_old
          exact h_inv (k, n) h_old.1 h_proxy
      · -- Proxy branch: new node has partition = -1
        dsimp at h_mem
        rw [addNode_nodeMap, List.mem_cons] at h_mem
        cases h_mem with
        | inl h_eq =>
          have := congrArg Prod.snd h_eq; simp at this; rw [this]
        | inr h_old =>
          rw [List.mem_filter] at h_old
          exact h_inv (k, n) h_old.1 h_proxy

/-- versionMonotonic is preserved by reconcileStep (direct proof). -/
theorem versionMonotonic_step :
    ∀ (state : FlareClusterState) (crd : FlareClusterView) (event : FlareEvent),
      versionMonotonic state (reconcileStep state crd event).1 := by
  intro state crd event
  unfold versionMonotonic
  cases event with
  | Ping => simp [reconcileStep]
  | Meta => simp [reconcileStep]
  | Stats => simp [reconcileStep]
  | Version => simp [reconcileStep]
  | Quit => simp [reconcileStep]
  | NodeSync _ => simp [reconcileStep]
  | NodeRemove _ _ => simp [reconcileStep]
  | MutationAttempt _ => simp [reconcileStep]
  | ParseError _ => simp [reconcileStep]
  | NodeAdd name port =>
    unfold reconcileStep; simp only []
    have h := autoAssign_version state crd (FlareClusterState.toNodeKey name port)
                { serverName := name, serverPort := port,
                  role := FlareRole.Proxy, state := FlareState.Active,
                  partition := -1, balance := 100, threadType := 16 }
    omega

/-- atMostOneMasterPerPartition is preserved by reconcileStep (direct proof).
    Uses metric reduction: for Slave/Proxy branches, role contradiction;
    for Master branch, old×old delegates to original invariant;
    for new×old cases, uses findPartitionNeedingMaster spec via
    partitionMap/nodeMap consistency. -/
theorem atMostOneMasterPerPartition_step :
    ∀ (state : FlareClusterState) (crd : FlareClusterView) (event : FlareEvent),
      atMostOneMasterPerPartition state →
      atMostOneMasterPerPartition (reconcileStep state crd event).1 := by
  intro state crd event h_inv
  cases event with
  | Ping => exact h_inv
  | Meta => exact h_inv
  | Stats => exact h_inv
  | Version => exact h_inv
  | Quit => exact h_inv
  | NodeSync _ => exact h_inv
  | NodeRemove _ _ => exact h_inv
  | MutationAttempt _ => exact h_inv
  | ParseError _ => exact h_inv
  | NodeAdd serverName serverPort =>
    unfold atMostOneMasterPerPartition reconcileStep
    simp only []
    unfold autoAssign
    simp only []
    split
    · -- Master branch: findPartitionNeedingMaster returned some pIdx
      rename_i pIdx h_find
      intro k1 k2 n1 n2 h1 h2 hr1 hr2 hp
      dsimp at h1 h2
      rw [setPartition_nodeMap] at h1 h2
      rw [addNode_nodeMap] at h1 h2
      rw [List.mem_cons] at h1 h2
      cases h1 with
      | inl h1_eq =>
        cases h2 with
        | inl h2_eq =>
          exact (congrArg Prod.fst h1_eq).trans (congrArg Prod.fst h2_eq).symm
        | inr h2_old =>
          -- Metric reduction: new Master at pIdx + existing Master at pIdx → contradiction
          exfalso
          rw [List.mem_filter] at h2_old
          have h_n1_part : n1.partition = Int.ofNat pIdx := by
            have := congrArg (FlareNode.partition ∘ Prod.snd) h1_eq; simp at this; exact this
          exact findPartitionNeedingMaster_noMaster state _ pIdx h_find
            k2 n2 h2_old.1 hr2 (hp ▸ h_n1_part)
      | inr h1_old =>
        cases h2 with
        | inl h2_eq =>
          -- Symmetric: metric reduction
          exfalso
          rw [List.mem_filter] at h1_old
          have h_n2_part : n2.partition = Int.ofNat pIdx := by
            have := congrArg (FlareNode.partition ∘ Prod.snd) h2_eq; simp at this; exact this
          exact findPartitionNeedingMaster_noMaster state _ pIdx h_find
            k1 n1 h1_old.1 hr1 (hp ▸ h_n2_part)
        | inr h2_old =>
          rw [List.mem_filter] at h1_old h2_old
          exact h_inv k1 k2 n1 n2 h1_old.1 h2_old.1 hr1 hr2 hp
    · split
      · -- Slave branch: role = Slave ≠ Master
        intro k1 k2 n1 n2 h1 h2 hr1 hr2 hp
        dsimp at h1 h2
        rw [setPartition_nodeMap] at h1 h2
        rw [addNode_nodeMap] at h1 h2
        rw [List.mem_cons] at h1 h2
        cases h1 with
        | inl h1_eq =>
          exfalso
          have := congrArg (FlareNode.role ∘ Prod.snd) h1_eq
          simp at this; rw [this] at hr1; exact absurd hr1 (by decide)
        | inr h1_old =>
          cases h2 with
          | inl h2_eq =>
            exfalso
            have := congrArg (FlareNode.role ∘ Prod.snd) h2_eq
            simp at this; rw [this] at hr2; exact absurd hr2 (by decide)
          | inr h2_old =>
            rw [List.mem_filter] at h1_old h2_old
            exact h_inv k1 k2 n1 n2 h1_old.1 h2_old.1 hr1 hr2 hp
      · -- Proxy branch: role = Proxy ≠ Master
        intro k1 k2 n1 n2 h1 h2 hr1 hr2 hp
        dsimp at h1 h2
        rw [addNode_nodeMap] at h1 h2
        rw [List.mem_cons] at h1 h2
        cases h1 with
        | inl h1_eq =>
          exfalso
          have := congrArg (FlareNode.role ∘ Prod.snd) h1_eq
          simp at this; rw [this] at hr1; exact absurd hr1 (by decide)
        | inr h1_old =>
          cases h2 with
          | inl h2_eq =>
            exfalso
            have := congrArg (FlareNode.role ∘ Prod.snd) h2_eq
            simp at this; rw [this] at hr2; exact absurd hr2 (by decide)
          | inr h2_old =>
            rw [List.mem_filter] at h1_old h2_old
            exact h_inv k1 k2 n1 n2 h1_old.1 h2_old.1 hr1 hr2 hp

-- ===========================================================================
-- Bridge: reconcileStep satisfies validFlareTransition
-- ===========================================================================

/-- reconcileStep produces valid transitions.
    The 2 sorry's in the Master branch of atMostOneMasterPerPartition_step
    propagate here. All other conjuncts are fully proved. -/
theorem reconcileStep_valid (state : FlareClusterState) (crd : FlareClusterView)
    (event : FlareEvent) (h_master : atMostOneMasterPerPartition state)
    (h_proxy : proxiesUnassigned state) :
    validFlareTransition state (reconcileStep state crd event).1 := by
  exact ⟨atMostOneMasterPerPartition_step state crd event h_master,
         proxiesUnassigned_step state crd event h_proxy,
         versionMonotonic_step state crd event⟩

-- ===========================================================================
-- Combined Safety Property (gungnir pattern)
-- ===========================================================================

def safetyInvariant (state : FlareClusterState) : Prop :=
  atMostOneMasterPerPartition state ∧
  proxiesUnassigned state

theorem safetyInvariant_init :
    safetyInvariant FlareClusterState.default :=
  ⟨atMostOneMasterPerPartition_init, proxiesUnassigned_init⟩

end FlareOperator.Invariants
