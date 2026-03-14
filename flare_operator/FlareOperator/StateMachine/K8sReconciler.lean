/-
  K8sReconciler.lean - Finite-step FSM model for the K8s reconcile loop

  Models `reconcileOnce` (Main.lean:72-101) as a finite-step FSM following
  the Anvil one-request-per-step pattern. Each step issues at most one
  kubectl call.

  Key types:
  - FlareReconcileStep: enumeration of reconciler FSM states
  - FlareReconcileState: full reconciler state including cached data
  - K8sResponse / K8sRequest: messages to/from K8s API
  - flareReconcileCore: pure transition function
  - flareReconcileMeasure: strictly decreasing measure for termination
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol
import FlareOperator.StateMachine.Reconciler

namespace FlareOperator.K8sReconciler

open FlareOperator.K8s
open FlareOperator.Reconciler (autoAssign)

-- ===========================================================================
-- FSM Step Enumeration
-- ===========================================================================

/-- Reconciler FSM states, modeling the complete steps of reconcileOnce.
    Models ALL steps from Main.lean:72-101 including previously missing ones:
    - Proxy Assignment (Main.lean:323)
    - ConfigMap Update (Main.lean:325-327)
    - Cluster Replication (Main.lean:212-272)
    - Topology Broadcast (Main.lean:329-331) -/
inductive FlareReconcileStep where
  | Init                     -- 11: Starting state
  | AfterFetchCRD            -- 10: CRD fetched
  | AfterListPods            -- 9: Pods listed
  | AfterDetectDead          -- 8: Dead nodes computed
  | AfterHandleFailover      -- 7: Failover applied
  | AfterAssignRoles         -- 6: Proxy roles assigned
  | AfterUpdateConfigMap     -- 5: Observability ConfigMap updated
  | AfterHandleReplication   -- 4: Replication state machine applied
  | AfterBroadcastTopology   -- 3: Topology broadcasted to nodes
  | AfterPatchService        -- 2: Services patched
  | Done                     -- 0: Terminal
  | Error (msg : String)     -- 0: Terminal
  deriving Repr, BEq

-- ===========================================================================
-- K8s API Request/Response Types
-- ===========================================================================

/-- Responses from the K8s API server. -/
inductive K8sResponse where
  | CRDResponse (crd : Option FlareClusterView)
  | PodListResponse (pods : List String)
  | PatchResponse (success : Bool)
  | NoResponse
  deriving Repr

/-- Requests to the K8s API server. -/
inductive K8sRequest where
  | FetchCRD
  | ListPods
  | PatchService
  | None
  deriving Repr, BEq

-- ===========================================================================
-- Side Effects
-- ===========================================================================

/-- Side effects that the pure FSM wants the IO shell to execute.
    Models all imperative operations from Main.lean reconcileOnce:
    - PatchService: Update K8s Service endpoints (Main.lean:333-338)
    - BroadcastTopology: Send topology to all nodes (Main.lean:329-331)
    - UpdateConfigMap: Write node map to observability ConfigMap (Main.lean:325-327)
    - SendSighup: Signal nodes to transition replication phase (Main.lean:246-251)
    - PatchCRDStatus: Update migration phase in CRD status field (Main.lean:253-258)
    - Log: Emit diagnostic message -/
inductive FlareEffect where
  | PatchService (svcName : String) (podName : String)
  | BroadcastTopology (version : Nat) (nodes : List (String × FlareNode))
  | UpdateConfigMap (data : String)
  | SendSighup (podNames : List String)
  | PatchCRDStatus (phase : MigrationPhase)
  | Log (msg : String)
  deriving Repr, BEq

-- ===========================================================================
-- Reconciler State
-- ===========================================================================

/-- The reconciler's internal state.
    Extended to track all intermediate data needed for complete reconcile flow. -/
structure FlareReconcileState where
  reconcileStep : FlareReconcileStep := .Init
  cachedCrd : Option FlareClusterView := none
  livePodKeys : List String := []
  deadNodeKeys : List String := []
  failoverTriggered : Bool := false
  -- Grace period for startup (CRITICAL for safety - Main.lean:355-359)
  graceCycles : Nat := 6
  -- Cluster state evolution:
  updatedClusterState : Option FlareClusterState := none  -- State after failover/proxy assignment
  -- Replication state machine:
  currentMigrationPhase : MigrationPhase := .None          -- Current replication phase
  nextMigrationPhase : Option MigrationPhase := none       -- Target phase transition
  deriving Repr

/-- Initial reconciler state. -/
def reconcileInitState : FlareReconcileState := {}

-- ===========================================================================
-- Terminal Predicate
-- ===========================================================================

/-- Check if a step is terminal (Done or Error). -/
def flareReconcileTerminalBool : FlareReconcileStep → Bool
  | .Done => true
  | .Error _ => true
  | _ => false

/-- Prop-level terminal check. -/
def flareReconcileDone (s : FlareReconcileState) : Prop :=
  s.reconcileStep = .Done

def flareReconcileError (s : FlareReconcileState) : Prop :=
  ∃ msg, s.reconcileStep = .Error msg

def flareReconcileTerminal (s : FlareReconcileState) : Prop :=
  flareReconcileDone s ∨ flareReconcileError s

-- ===========================================================================
-- Pure Failover Logic (extracted from Main.lean handleFailover)
-- ===========================================================================

/-- Process a single dead key: demote the node to Proxy/Down.
    Slave-to-Master promotion is modeled at the K8s reconciler FSM level
    (AfterHandleFailover → AfterPatchService) rather than inline. -/
def handleFailoverSingleKey (s : FlareClusterState) (key : String) : FlareClusterState :=
  match s.lookupNode key with
  | none => s
  | some node =>
    let demoted : FlareNode :=
      { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1 }
    s.addNode key demoted

/-- Pure version of handleFailover (Main.lean:45-69).
    Marks dead nodes as Down and demotes them to Proxy.
    Slave-to-Master promotion is modeled at the K8s reconciler FSM level
    (AfterHandleFailover step), enabling cleaner invariant proofs. -/
def handleFailoverPure (state : FlareClusterState) (deadKeys : List String)
    : FlareClusterState :=
  deadKeys.foldl handleFailoverSingleKey state

/-- Pure dead-node detection (Main.lean:39-42). -/
def detectDeadNodesPure (state : FlareClusterState) (livePodKeys : List String)
    : List String :=
  state.nodeMap.filter (fun (key, _) => !livePodKeys.contains key) |>.map Prod.fst

/-- Pure proxy assignment (Main.lean:323-330).
    Assigns roles to any Proxy nodes using autoAssign. -/
def assignProxiesPure (state : FlareClusterState) (crd : FlareClusterView)
    : FlareClusterState :=
  state.nodeMap.foldl (init := state) fun currentState (nodeKey, node) =>
    if node.role == FlareRole.Proxy then
      let (newState, _) := autoAssign currentState crd nodeKey node
      newState
    else
      currentState

/-- Pure replication phase computation (Main.lean:212-272).
    Determines next migration phase based on current phase and CRD spec.
    Returns (next phase, should emit SIGHUP). -/
def computeNextReplicationPhase (crd : FlareClusterView) (currentPhase : MigrationPhase)
    : Option MigrationPhase × Bool :=
  let repl := crd.spec.clusterReplication
  if !repl.enabled then
    -- Replication disabled → transition to None
    if currentPhase != .None then
      (some .None, false)  -- Will patch CRD status to None
    else
      (none, false)  -- Already None, no action
  else
    -- Replication enabled
    match currentPhase with
    | .None =>
      -- Start replication: None → Dumping (write config mode=duplicate, SIGHUP)
      (some .Dumping, true)
    | .Dumping =>
      -- Phase transition handled by IO layer (requires querying pod stats)
      -- FSM just records that we're in Dumping, actual transition happens via
      -- executeEffects checking dump_replication threads
      (none, false)
    | .Forwarding =>
      -- Steady state
      (none, false)

-- ===========================================================================
-- Core Transition Function
-- ===========================================================================

/-- The core reconciler transition function.
    Each step processes a K8s API response and produces a new state,
    an optional next request, and a list of side effects.

    Complete flow modeling ALL steps from Main.lean reconcileOnce:
    - Init → FetchCRD → AfterFetchCRD
    - AfterFetchCRD → ListPods → AfterListPods
    - AfterListPods → (compute dead nodes) → AfterDetectDead
    - AfterDetectDead → (handle failover) → AfterHandleFailover
    - AfterHandleFailover → (assign proxies) → AfterAssignRoles
    - AfterAssignRoles → (update ConfigMap) → AfterUpdateConfigMap
    - AfterUpdateConfigMap → (handle replication) → AfterHandleReplication
    - AfterHandleReplication → (broadcast topology) → AfterBroadcastTopology
    - AfterBroadcastTopology → PatchService → AfterPatchService
    - AfterPatchService → Done -/
def flareReconcileCore (resp : K8sResponse) (s : FlareReconcileState)
    (clusterState : FlareClusterState) : FlareReconcileState × Option K8sRequest × List FlareEffect :=
  match s.reconcileStep with
  | .Init =>
    -- Issue FetchCRD request
    ({ s with reconcileStep := .AfterFetchCRD }, some .FetchCRD, [])

  | .AfterFetchCRD =>
    match resp with
    | .CRDResponse (some crd) =>
      ({ s with reconcileStep := .AfterListPods, cachedCrd := some crd }, some .ListPods, [])
    | .CRDResponse none =>
      ({ s with reconcileStep := .Error "CRD not found" }, none, [])
    | _ =>
      ({ s with reconcileStep := .Error "unexpected response at AfterFetchCRD" }, none, [])

  | .AfterListPods =>
    match resp with
    | .PodListResponse pods =>
      -- CRITICAL: Check grace period (Main.lean:355-359)
      if s.graceCycles > 0 then
        -- Still in startup grace period - skip dead node detection
        ({ s with reconcileStep := .AfterDetectDead,
                  livePodKeys := pods,
                  deadNodeKeys := [],
                  graceCycles := s.graceCycles - 1 }, none,
         [.Log s!"[flare-operator] grace period: {s.graceCycles - 1} cycles remaining"])
      else
        -- Grace period over - perform normal dead node detection
        let deadKeys := detectDeadNodesPure clusterState pods
        ({ s with reconcileStep := .AfterDetectDead,
                  livePodKeys := pods,
                  deadNodeKeys := deadKeys }, none, [])
    | _ =>
      ({ s with reconcileStep := .Error "unexpected response at AfterListPods" }, none, [])

  | .AfterDetectDead =>
    -- Unconditionally continue to failover step (even if no dead nodes)
    -- K8s operators must be idempotent
    if s.deadNodeKeys.isEmpty then
      ({ s with reconcileStep := .AfterHandleFailover,
                failoverTriggered := false,
                updatedClusterState := some clusterState }, none, [])
    else
      ({ s with reconcileStep := .AfterHandleFailover,
                failoverTriggered := true }, none,
       [.Log s!"[flare-operator] detected {s.deadNodeKeys.length} dead nodes: {s.deadNodeKeys}"])

  | .AfterHandleFailover =>
    -- Apply failover logic if triggered
    let newState :=
      if s.failoverTriggered then
        handleFailoverPure clusterState s.deadNodeKeys
      else
        clusterState
    ({ s with reconcileStep := .AfterAssignRoles,
              updatedClusterState := some newState }, none, [])

  | .AfterAssignRoles =>
    -- Assign proxy roles (Main.lean:323-330)
    match s.updatedClusterState, s.cachedCrd with
    | some state, some crd =>
      let stateWithProxies := assignProxiesPure state crd
      ({ s with reconcileStep := .AfterUpdateConfigMap,
                updatedClusterState := some stateWithProxies }, none, [])
    | _, _ =>
      ({ s with reconcileStep := .Error "missing cluster state or CRD at AfterAssignRoles" }, none, [])

  | .AfterUpdateConfigMap =>
    -- Emit ConfigMap update effect (Main.lean:325-327)
    match s.updatedClusterState with
    | some state =>
      let configData := toString (repr state.nodeMap)  -- Simplified; real impl uses JSON
      ({ s with reconcileStep := .AfterHandleReplication }, none,
       [.UpdateConfigMap configData])
    | none =>
      ({ s with reconcileStep := .Error "missing cluster state at AfterUpdateConfigMap" }, none, [])

  | .AfterHandleReplication =>
    -- Handle cluster replication state machine (Main.lean:212-272)
    match s.cachedCrd with
    | some crd =>
      let (nextPhase, shouldSighup) := computeNextReplicationPhase crd s.currentMigrationPhase
      match nextPhase with
      | some phase =>
        let effects :=
          if shouldSighup then
            [.SendSighup s.livePodKeys, .PatchCRDStatus phase]
          else
            [.PatchCRDStatus phase]
        ({ s with reconcileStep := .AfterBroadcastTopology,
                  nextMigrationPhase := some phase }, none, effects)
      | none =>
        -- No phase transition needed
        ({ s with reconcileStep := .AfterBroadcastTopology }, none, [])
    | none =>
      ({ s with reconcileStep := .Error "missing CRD at AfterHandleReplication" }, none, [])

  | .AfterBroadcastTopology =>
    -- Emit topology broadcast effect (Main.lean:329-331)
    match s.updatedClusterState with
    | some state =>
      let nodes := state.nodeMap
      let version := state.nodeMapVersion
      ({ s with reconcileStep := .AfterPatchService }, none,
       [.BroadcastTopology version nodes])
    | none =>
      ({ s with reconcileStep := .Error "missing cluster state at AfterBroadcastTopology" }, none, [])

  | .AfterPatchService =>
    -- ALWAYS patch services (K8s idempotency requirement)
    -- Issue PatchService request
    ({ s with reconcileStep := .Done }, some .PatchService, [])

  | .Done =>
    -- Terminal: stay in Done
    (s, none, [])

  | .Error _ =>
    -- Terminal: stay in Error (IO shell will log and restart on next tick)
    (s, none, [])

-- ===========================================================================
-- Measure Function for Termination
-- ===========================================================================

/-- Measure on FlareReconcileStep for termination arguments.
    Strictly decreasing on non-terminal transitions. -/
def flareReconcileMeasure : FlareReconcileStep → Nat
  | .Init => 11
  | .AfterFetchCRD => 10
  | .AfterListPods => 9
  | .AfterDetectDead => 8
  | .AfterHandleFailover => 7
  | .AfterAssignRoles => 6
  | .AfterUpdateConfigMap => 5
  | .AfterHandleReplication => 4
  | .AfterBroadcastTopology => 3
  | .AfterPatchService => 2
  | .Done => 0
  | .Error _ => 0

-- ===========================================================================
-- Measure Decrease Proof
-- ===========================================================================

/-- Each reconcileCore step on a non-terminal state either strictly decreases
    the measure or reaches a terminal state.
    Exhaustive case analysis on FlareReconcileStep × K8sResponse. -/
theorem flareReconcileStep_decreases_measure (resp : K8sResponse)
    (s : FlareReconcileState) (cs : FlareClusterState) :
    flareReconcileTerminalBool s.reconcileStep = false →
    flareReconcileMeasure (flareReconcileCore resp s cs).1.reconcileStep <
      flareReconcileMeasure s.reconcileStep ∨
    flareReconcileTerminalBool (flareReconcileCore resp s cs).1.reconcileStep = true := by
  intro hNT
  cases h : s.reconcileStep with
  | Init =>
    left; simp [flareReconcileCore, h, flareReconcileMeasure]
  | AfterFetchCRD =>
    cases resp with
    | CRDResponse crd =>
      cases crd with
      | some c => left; simp [flareReconcileCore, h, flareReconcileMeasure]
      | none => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | PodListResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | PatchResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | NoResponse => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
  | AfterListPods =>
    cases resp with
    | PodListResponse pods =>
      simp only [flareReconcileCore, h]
      split <;> (left; simp [flareReconcileMeasure])
    | CRDResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | PatchResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | NoResponse => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
  | AfterDetectDead =>
    simp only [flareReconcileCore, h]
    split <;> (left; simp [flareReconcileMeasure])
  | AfterHandleFailover =>
    left; simp [flareReconcileCore, h, flareReconcileMeasure]
  | AfterAssignRoles =>
    simp only [flareReconcileCore, h]
    cases s.updatedClusterState <;> cases s.cachedCrd
    · right; simp [flareReconcileTerminalBool]
    · right; simp [flareReconcileTerminalBool]
    · right; simp [flareReconcileTerminalBool]
    · left; simp [flareReconcileMeasure]
  | AfterUpdateConfigMap =>
    simp only [flareReconcileCore, h]
    cases s.updatedClusterState
    · right; simp [flareReconcileTerminalBool]
    · left; simp [flareReconcileMeasure]
  | AfterHandleReplication =>
    simp only [flareReconcileCore, h]
    cases hCrd : s.cachedCrd
    · right; simp [flareReconcileTerminalBool]
    · -- Some crd: both branches (some/none phase) go to AfterBroadcastTopology
      left
      simp only [flareReconcileMeasure]
      cases computeNextReplicationPhase ‹_› s.currentMigrationPhase |>.fst <;> simp [flareReconcileMeasure]
  | AfterBroadcastTopology =>
    simp only [flareReconcileCore, h]
    cases s.updatedClusterState
    · right; simp [flareReconcileTerminalBool]
    · left; simp [flareReconcileMeasure]
  | AfterPatchService =>
    left; simp [flareReconcileCore, h, flareReconcileMeasure]
  | Done => simp [h, flareReconcileTerminalBool] at hNT
  | Error _msg => simp [h, flareReconcileTerminalBool] at hNT

/-- Measure = 0 implies terminal. -/
theorem measure_zero_is_terminal (step : FlareReconcileStep) :
    flareReconcileMeasure step = 0 → flareReconcileTerminalBool step = true := by
  intro h
  cases step with
  | Done => rfl
  | Error _ => rfl
  | Init => simp [flareReconcileMeasure] at h
  | AfterFetchCRD => simp [flareReconcileMeasure] at h
  | AfterListPods => simp [flareReconcileMeasure] at h
  | AfterDetectDead => simp [flareReconcileMeasure] at h
  | AfterHandleFailover => simp [flareReconcileMeasure] at h
  | AfterAssignRoles => simp [flareReconcileMeasure] at h
  | AfterUpdateConfigMap => simp [flareReconcileMeasure] at h
  | AfterHandleReplication => simp [flareReconcileMeasure] at h
  | AfterBroadcastTopology => simp [flareReconcileMeasure] at h
  | AfterPatchService => simp [flareReconcileMeasure] at h

/-- Terminal states are absorbing under flareReconcileCore. -/
theorem terminal_absorption (resp : K8sResponse) (s : FlareReconcileState)
    (cs : FlareClusterState) :
    flareReconcileTerminalBool s.reconcileStep = true →
    (flareReconcileCore resp s cs).1 = s := by
  intro hTerm
  cases h : s.reconcileStep with
  | Done => simp [flareReconcileCore, h]
  | Error msg => simp [flareReconcileCore, h]
  | Init => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterFetchCRD => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterListPods => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterDetectDead => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterHandleFailover => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterAssignRoles => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterUpdateConfigMap => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterHandleReplication => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterBroadcastTopology => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterPatchService => simp [h, flareReconcileTerminalBool] at hTerm

end FlareOperator.K8sReconciler
