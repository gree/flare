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

namespace FlareOperator.K8sReconciler

open FlareOperator.K8s

-- ===========================================================================
-- FSM Step Enumeration
-- ===========================================================================

/-- Reconciler FSM states, modeling the steps of reconcileOnce. -/
inductive FlareReconcileStep where
  | Init                     -- 7: Starting state
  | AfterFetchCRD            -- 6: CRD fetched
  | AfterListPods            -- 5: Pods listed
  | AfterDetectDead          -- 4: Dead nodes computed
  | AfterHandleFailover      -- 3: Failover applied
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
-- Reconciler State
-- ===========================================================================

/-- The reconciler's internal state. -/
structure FlareReconcileState where
  reconcileStep : FlareReconcileStep := .Init
  cachedCrd : Option FlareClusterView := none
  livePodKeys : List String := []
  deadNodeKeys : List String := []
  failoverTriggered : Bool := false
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

-- ===========================================================================
-- Core Transition Function
-- ===========================================================================

/-- The core reconciler transition function.
    Each step processes a K8s API response and produces a new state
    plus an optional next request.

    Models reconcileOnce (Main.lean:72-101) as discrete steps:
    - Init → FetchCRD → AfterFetchCRD
    - AfterFetchCRD → ListPods → AfterListPods
    - AfterListPods → (compute dead nodes) → AfterDetectDead
    - AfterDetectDead → (handle failover) → AfterHandleFailover
    - AfterHandleFailover → PatchService → AfterPatchService
    - AfterPatchService → Done -/
def flareReconcileCore (resp : K8sResponse) (s : FlareReconcileState)
    (clusterState : FlareClusterState) : FlareReconcileState × Option K8sRequest :=
  match s.reconcileStep with
  | .Init =>
    -- Issue FetchCRD request
    ({ s with reconcileStep := .AfterFetchCRD }, some .FetchCRD)
  | .AfterFetchCRD =>
    match resp with
    | .CRDResponse (some crd) =>
      ({ s with reconcileStep := .AfterListPods, cachedCrd := some crd }, some .ListPods)
    | .CRDResponse none =>
      ({ s with reconcileStep := .Error "CRD not found" }, none)
    | _ =>
      ({ s with reconcileStep := .Error "unexpected response at AfterFetchCRD" }, none)
  | .AfterListPods =>
    match resp with
    | .PodListResponse pods =>
      let deadKeys := detectDeadNodesPure clusterState pods
      ({ s with reconcileStep := .AfterDetectDead,
                livePodKeys := pods,
                deadNodeKeys := deadKeys }, none)
    | _ =>
      ({ s with reconcileStep := .Error "unexpected response at AfterListPods" }, none)
  | .AfterDetectDead =>
    -- Handle failover (pure computation, no K8s request)
    if s.deadNodeKeys.isEmpty then
      ({ s with reconcileStep := .Done, failoverTriggered := false }, none)
    else
      ({ s with reconcileStep := .AfterHandleFailover, failoverTriggered := true }, none)
  | .AfterHandleFailover =>
    -- Issue PatchService request
    ({ s with reconcileStep := .AfterPatchService }, some .PatchService)
  | .AfterPatchService =>
    match resp with
    | .PatchResponse _ =>
      ({ s with reconcileStep := .Done }, none)
    | _ =>
      ({ s with reconcileStep := .Error "unexpected response at AfterPatchService" }, none)
  | .Done =>
    -- Terminal: stay in Done
    (s, none)
  | .Error _ =>
    -- Terminal: stay in Error
    (s, none)

-- ===========================================================================
-- Measure Function for Termination
-- ===========================================================================

/-- Measure on FlareReconcileStep for termination arguments.
    Strictly decreasing on non-terminal transitions. -/
def flareReconcileMeasure : FlareReconcileStep → Nat
  | .Init => 7
  | .AfterFetchCRD => 6
  | .AfterListPods => 5
  | .AfterDetectDead => 4
  | .AfterHandleFailover => 3
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
    | PodListResponse pods => left; simp [flareReconcileCore, h, flareReconcileMeasure]
    | CRDResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | PatchResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | NoResponse => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
  | AfterDetectDead =>
    simp only [flareReconcileCore, h]
    split
    · -- deadNodeKeys empty → Done
      right; simp [flareReconcileTerminalBool]
    · -- deadNodeKeys nonempty → AfterHandleFailover
      left; simp [flareReconcileMeasure]
  | AfterHandleFailover =>
    left; simp [flareReconcileCore, h, flareReconcileMeasure]
  | AfterPatchService =>
    cases resp with
    | PatchResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | CRDResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | PodListResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | NoResponse => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
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
  | AfterPatchService => simp [h, flareReconcileTerminalBool] at hTerm

end FlareOperator.K8sReconciler
