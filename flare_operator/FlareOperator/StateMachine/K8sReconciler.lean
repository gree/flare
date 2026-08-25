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
    - Topology Broadcast (Main.lean:329-331)
    - Emergency Pause (Circuit Breaker for AZ-level failures) -/
inductive FlareReconcileStep where
  | Init                     -- 12: Starting state
  | AfterFetchCRD            -- 11: CRD fetched
  | AfterListPods            -- 10: Pods listed
  | AfterDetectDead          -- 9: Dead nodes computed
  | RecoveryRefill           -- 8: Breaker tripped — masterless-refill-only recovery pass
  | EmergencyPaused          -- 0: Circuit breaker tripped and nothing refillable - fully inert
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
  | PodListResponse (pods : List String) (zones : List (String × String)) (terminating : List String)
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
  /-- nodeKey → zone, from the last pod listing ([] when topology unknown). -/
  podZones : List (String × String) := []
  deadNodeKeys : List String := []
  /-- Node keys of Terminating pods (deletionTimestamp set) this tick. Used to
      exclude a draining node from role re-assignment (it must stay a proxy). -/
  terminatingKeys : List String := []
  /-- Terminating nodes that are still Master/Slave and must be drained this
      tick: promote a replacement + demote them to a live proxy. -/
  drainNodeKeys : List String := []
  /-- Draining masters the drain guard REFUSED to demote (no promotable
      successor). Carried to Done so the driver can export the
      flare_operator_drain_no_successor gauge — this is a CRITICAL,
      human-decision condition (see drainBlockedKeys). -/
  drainBlockedCount : Nat := 0
  /-- Node keys matched by spec.readBalance.standby this tick (by pod name or
      zone). Forced to balance 0 at commit; deprioritized for promotion. -/
  standbyNodeKeys : List String := []
  failoverTriggered : Bool := false
  -- Grace period for startup: 24 cycles × 5s = 120s (see Main.lean)
  graceCycles : Nat := 24
  /-- Whether the breaker was tripped at the END of the previous cycle
      (persisted via trippedRef in the IO shell — FSM state itself resets
      every tick). Input to the reset-hysteresis: once tripped, recovery
      requires healthy% ≥ resetThresholdPercent, not merely dropping below
      the trip threshold, so the breaker cannot flap around one boundary. -/
  wasTripped : Bool := false
  /-- OUTPUT: the breaker held (tripped) during THIS pass. Distinct from the
      terminal step: a tripped pass that performs a masterless refill ends in
      Done, not EmergencyPaused, yet must still count as tripped for next
      cycle's hysteresis — the IO shell persists (breakerHeld ∨ ended in
      EmergencyPaused) into trippedRef. -/
  breakerHeld : Bool := false
  -- Cluster state evolution:
  updatedClusterState : Option FlareClusterState := none  -- State after failover/proxy assignment
  -- Replication state machine:
  currentMigrationPhase : MigrationPhase := .None          -- Current replication phase
  nextMigrationPhase : Option MigrationPhase := none       -- Target phase transition
  deriving Repr

/-- Initial reconciler state. -/
def reconcileInitState : FlareReconcileState := {}

-- ===========================================================================
-- Circuit Breaker Helper
-- ===========================================================================

/-- Circuit breaker decision: should we trip or continue with failover?
    Returns (nextStep, effects) -/
def circuitBreakerDecision
    (deadCount : Nat)
    (totalNodes : Nat)
    (breakerCfg : CircuitBreakerConfig)
    (wasTripped : Bool := false)
    : FlareReconcileStep × List FlareEffect :=
  if !breakerCfg.enabled then
    (.AfterHandleFailover,
     [.Log s!"[flare-operator] Circuit breaker DISABLED - automatic recovery enabled"])
  else
    let deadPercent := if totalNodes > 0 then (deadCount * 100) / totalNodes else 0
    if wasTripped then
      -- Reset hysteresis (resetThresholdPercent was previously dead config —
      -- external review P1-5): a tripped breaker stays tripped until the
      -- HEALTHY fraction reaches the reset threshold, i.e. deadPercent ≤
      -- 100 - reset. With trip=50/reset=80 the cluster must recover to 80%
      -- healthy before failover resumes — recovering to 51% no longer flaps
      -- the breaker around the trip boundary. autoResetEnabled=false holds
      -- the trip regardless (operator restart = the manual reset).
      if !breakerCfg.autoResetEnabled then
        (.EmergencyPaused,
         [.Log s!"[flare-operator] circuit breaker HELD (autoResetEnabled=false): {deadCount}/{totalNodes} dead — manual reset = operator restart"])
      else if deadPercent ≤ 100 - breakerCfg.resetThresholdPercent then
        (.AfterHandleFailover,
         [.Log s!"[flare-operator] circuit breaker RESET: {100 - deadPercent}% healthy ≥ {breakerCfg.resetThresholdPercent}% — resuming failover"])
      else
        -- Holding, but via RecoveryRefill: masterless-partition refill (pure
        -- recovery — see the RecoveryRefill step) still runs so a returning
        -- node can be seated and turn Active. Without it, sync-gated readiness
        -- + OrderedReady StatefulSets deadlock: the returning pod never turns
        -- Active(=Ready), the next dead pod is never recreated, and the dead
        -- fraction can never fall below the reset threshold.
        (.RecoveryRefill,
         [.Log s!"[flare-operator] circuit breaker holding: {100 - deadPercent}% healthy < reset threshold {breakerCfg.resetThresholdPercent}% (masterless-refill-only recovery)"])
    else if deadPercent >= breakerCfg.tripThresholdPercent then
      (.RecoveryRefill,
       [.Log s!"[flare-operator] 🚨 CIRCUIT BREAKER TRIPPED: {deadCount}/{totalNodes} nodes dead ({deadPercent}% ≥ {breakerCfg.tripThresholdPercent}%)",
        .Log s!"[flare-operator] Suspected AZ failure - failover/reassignment PAUSED (masterless-refill-only recovery continues)",
        .Log s!"[flare-operator] Surviving nodes continue serving traffic",
        .Log s!"[flare-operator] Recovery resumes AUTOMATICALLY once healthy capacity reaches {breakerCfg.resetThresholdPercent}% (each 5s tick re-evaluates); no operator restart needed"])
    else
      (.AfterHandleFailover, [])

/-- The breaker TRIPS exactly at/above the threshold (enabled, nonempty
    cluster, not already tripped). -/
theorem circuitBreakerDecision_trips (deadCount totalNodes : Nat)
    (cfg : CircuitBreakerConfig) (hen : cfg.enabled = true) (htot : 0 < totalNodes)
    (h : cfg.tripThresholdPercent ≤ (deadCount * 100) / totalNodes) :
    (circuitBreakerDecision deadCount totalNodes cfg false).1 = .RecoveryRefill := by
  unfold circuitBreakerDecision
  simp only [hen, Bool.not_true, Bool.false_eq_true, if_false]
  have ht : (0 < totalNodes) = True := eq_true htot
  simp only [show (totalNodes > 0) = True from ht, if_true]
  rw [if_pos h]

/-- Below the threshold a fresh (not-tripped) breaker NEVER trips:
    failover proceeds. -/
theorem circuitBreakerDecision_no_trip (deadCount totalNodes : Nat)
    (cfg : CircuitBreakerConfig) (htot : 0 < totalNodes)
    (h : (deadCount * 100) / totalNodes < cfg.tripThresholdPercent) :
    (circuitBreakerDecision deadCount totalNodes cfg false).1 = .AfterHandleFailover := by
  unfold circuitBreakerDecision
  cases hen : cfg.enabled with
  | false => simp
  | true =>
    simp only [Bool.not_true, Bool.false_eq_true, if_false]
    have ht : (0 < totalNodes) = True := eq_true htot
    simp only [show (totalNodes > 0) = True from ht, if_true]
    rw [if_neg (by omega)]

/-- HYSTERESIS, holding side: a tripped breaker stays tripped while the
    healthy fraction is below the reset threshold — even when the dead
    fraction has already dropped below the TRIP threshold. This is the
    anti-flap property resetThresholdPercent exists for (it was dead
    config before — external review P1-5). -/
theorem circuitBreakerDecision_holds_below_reset (deadCount totalNodes : Nat)
    (cfg : CircuitBreakerConfig) (hen : cfg.enabled = true)
    (har : cfg.autoResetEnabled = true) (htot : 0 < totalNodes)
    (h : 100 - cfg.resetThresholdPercent < (deadCount * 100) / totalNodes) :
    (circuitBreakerDecision deadCount totalNodes cfg true).1 = .RecoveryRefill := by
  unfold circuitBreakerDecision
  simp only [hen, har, Bool.not_true, Bool.false_eq_true, if_false, if_true]
  have ht : (0 < totalNodes) = True := eq_true htot
  simp only [show (totalNodes > 0) = True from ht, if_true]
  rw [if_neg (by omega)]

/-- HYSTERESIS, release side: once the healthy fraction reaches the reset
    threshold, an auto-reset breaker releases and failover resumes. -/
theorem circuitBreakerDecision_resets_at_threshold (deadCount totalNodes : Nat)
    (cfg : CircuitBreakerConfig) (hen : cfg.enabled = true)
    (har : cfg.autoResetEnabled = true) (htot : 0 < totalNodes)
    (h : (deadCount * 100) / totalNodes ≤ 100 - cfg.resetThresholdPercent) :
    (circuitBreakerDecision deadCount totalNodes cfg true).1 = .AfterHandleFailover := by
  unfold circuitBreakerDecision
  simp only [hen, har, Bool.not_true, Bool.false_eq_true, if_false, if_true]
  have ht : (0 < totalNodes) = True := eq_true htot
  simp only [show (totalNodes > 0) = True from ht, if_true]
  rw [if_pos h]

/-- autoResetEnabled = false holds a tripped breaker unconditionally:
    the manual reset is an operator restart. -/
theorem circuitBreakerDecision_manual_hold (deadCount totalNodes : Nat)
    (cfg : CircuitBreakerConfig) (hen : cfg.enabled = true)
    (har : cfg.autoResetEnabled = false) :
    (circuitBreakerDecision deadCount totalNodes cfg true).1 = .EmergencyPaused := by
  unfold circuitBreakerDecision
  simp [hen, har]

/-- circuitBreakerDecision only returns EmergencyPaused, RecoveryRefill, or
    AfterHandleFailover -/
theorem circuitBreakerDecision_only_returns_emergency_or_failover
    (deadCount totalNodes : Nat) (cfg : CircuitBreakerConfig) (wt : Bool) :
    (circuitBreakerDecision deadCount totalNodes cfg wt).1 = .EmergencyPaused ∨
    (circuitBreakerDecision deadCount totalNodes cfg wt).1 = .RecoveryRefill ∨
    (circuitBreakerDecision deadCount totalNodes cfg wt).1 = .AfterHandleFailover := by
  simp only [circuitBreakerDecision]
  repeat' split
  all_goals first | (left; rfl) | (right; left; rfl) | (right; right; rfl)

-- ===========================================================================
-- Terminal Predicate
-- ===========================================================================

/-- Check if a step is terminal (Done, Error, or EmergencyPaused).
    EmergencyPaused is terminal to prevent automatic recovery during AZ failures. -/
def flareReconcileTerminalBool : FlareReconcileStep → Bool
  | .Done => true
  | .Error _ => true
  | .EmergencyPaused => true
  | _ => false

/-- Prop-level terminal check. -/
def flareReconcileDone (s : FlareReconcileState) : Prop :=
  s.reconcileStep = .Done

def flareReconcileError (s : FlareReconcileState) : Prop :=
  ∃ msg, s.reconcileStep = .Error msg

def flareReconcileEmergencyPaused (s : FlareReconcileState) : Prop :=
  s.reconcileStep = .EmergencyPaused

def flareReconcileTerminal (s : FlareReconcileState) : Prop :=
  flareReconcileDone s ∨ flareReconcileError s ∨ flareReconcileEmergencyPaused s

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
      { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1,
                  lastMasterOf := if node.role == FlareRole.Master then node.partition
                                  else node.lastMasterOf }
    s.addNode key demoted

/-- Pure version of handleFailover (Main.lean:45-69).
    Marks dead nodes as Down and demotes them to Proxy.
    Slave-to-Master promotion is modeled at the K8s reconciler FSM level
    (AfterHandleFailover step), enabling cleaner invariant proofs. -/
def handleFailoverPure (state : FlareClusterState) (deadKeys : List String)
    : FlareClusterState :=
  deadKeys.foldl handleFailoverSingleKey state

/-- Process a single dead key WITH slave promotion (mirrors the legacy
    `handleFailover`, Main.lean:133-161).

    Demotes the dead node to Proxy/Down, and — crucially — if it was a Master,
    promotes a live Slave from the SAME partition to Master/Active so the
    partition's data (which the slave still holds) is preserved. Without this the
    empty pod that the StatefulSet recreates under the same name grabs the master
    slot and serves an empty dataset, silently losing the partition's data. The
    live slave is a DIFFERENT pod that was never killed, so promoting it keeps the
    data even without persistent volumes. -/
def handleFailoverWithPromotionSingleKey (s : FlareClusterState) (key : String)
    : FlareClusterState :=
  match s.lookupNode key with
  | none => s
  | some node =>
    -- Demote the dead node first. Stamp lastMasterOf: the rejoin path and the
    -- masterless refill identify "the node holding the newest copy of
    -- partition P" by this field, and the rejoin can no longer infer it from
    -- role once the corpse has been demoted to Proxy (observed live: the
    -- returning ex-master lost its refill candidacy and the partition stayed
    -- masterless until an unrelated resync).
    let demoted : FlareNode :=
      { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1,
                  lastMasterOf := if node.role == FlareRole.Master then node.partition
                                  else node.lastMasterOf }
    let s := s.addNode key demoted
    -- If it was a Master, promote a live slave of its partition.
    if node.role == FlareRole.Master then
      let partIdx := node.partition
      match s.partitionMap.find? (fun (idx, _) => Int.ofNat idx == partIdx) with
      | none => s
      | some (_, part) =>
        match part.slaves.head? with
        | none => s  -- no slave to promote; slot stays empty until a node registers
        | some slaveKey =>
          match s.lookupNode slaveKey with
          | none => s
          | some slaveNode =>
            -- Defensive: promote only a node that CURRENTLY has role Slave.
            -- The partitionMap the caller rebuilt should guarantee this, but
            -- checking here makes the precondition local — both hardening
            -- against a stale map and letting the general safety proof read
            -- the guarantee off this branch instead of trusting the caller.
            if slaveNode.role == FlareRole.Slave && slaveNode.partition == partIdx then
              let promoted := { slaveNode with role := FlareRole.Master,
                                               state := FlareState.Active, balance := 100 }
              let newPart := { part with master := some slaveKey, slaves := part.slaves.tail }
              (s.addNode slaveKey promoted).setPartition partIdx.toNat newPart
            else s
    else s

/-- Failover with slave promotion over all dead keys (see the single-key doc).
    This is what the running FSM path uses; it both demotes dead masters and
    promotes the surviving replica, preserving partition data across a master
    kill. -/
def handleFailoverWithPromotion (state : FlareClusterState) (deadKeys : List String)
    : FlareClusterState :=
  deadKeys.foldl handleFailoverWithPromotionSingleKey state

/-- Graceful drain of a single Terminating node. Same shape as
    `handleFailoverWithPromotionSingleKey` (demote the node to an unassigned
    Proxy; if it was a Master, promote a live slave of its partition) with TWO
    differences:
    1. The demoted node is left **state=Active**, not Down — it is a LIVE
       proxy, still running for the rest of its preStop window, so flared
       keeps serving and forwards its existing connections to the new master.
    2. A Master is demoted ONLY when a promotable successor actually exists.
       Failover demotes unconditionally because the node is already a corpse;
       here the node is still alive, and demoting the partition's only
       data-bearing node buys nothing — the partition just goes masterless
       (and stops taking writes) EARLIER than the pod's death. Observed live:
       deleting both pods of a 1p×2r cluster drained the slave first (making
       it a proxy), then the master found no promotable slave and was demoted
       anyway — masterless with every node still running. With the guard the
       doomed master keeps serving to the end of its grace period, maximizing
       what WAL replication / a final backup can still capture; the caller
       surfaces the no-successor condition as a CRITICAL signal (a human
       decision point — see drainBlockedKeys).
    (The at-most-one-master count is unaffected by the state field, and the
    guard only ever demotes FEWER masters, so the safety proof mirrors
    `handleFailoverSingle_cle`.) -/
def handleDrainWithPromotionSingleKey (s : FlareClusterState) (key : String)
    : FlareClusterState :=
  match s.lookupNode key with
  | none => s
  | some node =>
    if node.role == FlareRole.Master then
      -- Master: demote only together with a successful promotion.
      let partIdx := node.partition
      match s.partitionMap.find? (fun (idx, _) => Int.ofNat idx == partIdx) with
      | none => s
      | some (_, part) =>
        match part.slaves.head? with
        | none => s
        | some slaveKey =>
          match s.lookupNode slaveKey with
          | none => s
          | some slaveNode =>
            if slaveNode.role == FlareRole.Slave && slaveNode.partition == partIdx then
              let demoted : FlareNode :=
                { node with state := FlareState.Active, role := FlareRole.Proxy,
                            partition := -1 }
              let s := s.addNode key demoted
              let promoted := { slaveNode with role := FlareRole.Master,
                                               state := FlareState.Active, balance := 100 }
              let newPart := { part with master := some slaveKey, slaves := part.slaves.tail }
              (s.addNode slaveKey promoted).setPartition partIdx.toNat newPart
            else s
    else
      -- Slave (or already-proxy): demoting to a live proxy is always safe.
      s.addNode key
        { node with state := FlareState.Active, role := FlareRole.Proxy, partition := -1 }

/-- Drain every Terminating master/slave (see the single-key doc). -/
def handleDrainWithPromotion (state : FlareClusterState) (drainKeys : List String)
    : FlareClusterState :=
  drainKeys.foldl handleDrainWithPromotionSingleKey state

/-- Draining keys that are STILL Master after the drain pass = masters the
    guard refused to demote because no promotable successor existed. Computed
    on the POST-drain state so fold-order interactions are already settled
    (e.g. the partition's only slave was itself drained earlier in the pass).
    Each such key is a partition that will lose its only data-bearing node
    when the pod's grace period expires — normally unrecoverable in place
    (tmpfs: rewind to the last S3 backup; PVC: recovers when the pod returns).
    The operator cannot fix this; it must be surfaced to a human as CRITICAL. -/
def drainBlockedKeys (post : FlareClusterState) (drainKeys : List String)
    : List String :=
  drainKeys.filter fun key =>
    match post.lookupNode key with
    | some node => node.role == FlareRole.Master
    | none => false

/-- Demote every Master that duplicates an EARLIER Master of the same
    partition in the list (first Master for a partition wins; later ones are
    demoted back to an unassigned Proxy and will be re-assigned by the next
    reconcile tick).

    This is the repair step for the merge race: the FSM computes its state
    (`ucs`) from a snapshot while the TCP server can concurrently assign a
    master (the P0 fast path in `reconcileStep`) on the live ref. A merge
    that carries both forward would leave two Masters for one partition —
    a split-brain the rest of the system never repairs. Callers put the
    FSM-computed entries FIRST so the FSM's assignment is the survivor.

    Recursive worker: `seen` accumulates the partitions whose (first) Master
    has already been kept; any later Master of a partition in `seen` is
    demoted. Structural recursion (not a fold) so the safety theorem below
    goes through by plain induction. -/
def demoteDuplicateMastersGo (seen : List Int)
    : List (String × FlareNode) → List (String × FlareNode)
  | [] => []
  | (key, node) :: rest =>
    if node.role == FlareRole.Master then
      if seen.contains node.partition then
        let demoted := { node with role := FlareRole.Proxy,
                                   state := FlareState.Active,
                                   partition := -1,
                                   balance := 100 }
        (key, demoted) :: demoteDuplicateMastersGo seen rest
      else
        (key, node) :: demoteDuplicateMastersGo (node.partition :: seen) rest
    else
      (key, node) :: demoteDuplicateMastersGo seen rest

def demoteDuplicateMasters (nodeMap : List (String × FlareNode))
    : List (String × FlareNode) :=
  demoteDuplicateMastersGo [] nodeMap

/-- Role-consistent read balance, enforced level-triggered at the commit
    boundary: Master serves reads (100), Slave does not (0), Proxy keeps
    whatever it carries (irrelevant — proxies own no partition).

    Individual transitions (promotion, drain, autoAssign, rejoin, the
    merge's stale-entry rules) each try to set balance correctly, but their
    INTERLEAVINGS leaked: observed live after a rolling restart as the
    promoted master carrying balance 0 while the demoted ex-master rejoined
    as a slave still carrying 100 — silently flipping reads from the master
    (read-your-writes) to a lagging slave. Normalizing every committed map
    makes the policy hold no matter which path wrote the entry; it is
    idempotent, so the version-bump quiescence is unaffected once clean. -/
def normalizeBalanceEntry (mb sb : Nat) (standby : Bool) (n : FlareNode) : FlareNode :=
  -- Down corpses are exempt: they serve nothing, their balance is inert,
  -- and leaving them byte-identical keeps the no-corpse-resurrection
  -- theorem (`mergeClusterState_down_survives`) literally true.
  if n.state == FlareState.Down then n
  else if standby then
    -- standby nodes never serve reads regardless of role
    match n.role with
    | FlareRole.Master => { n with balance := 0 }
    | FlareRole.Slave  => { n with balance := 0 }
    | _ => n
  else match n.role with
    | FlareRole.Master => { n with balance := mb }
    | FlareRole.Slave  => { n with balance := sb }
    | _ => n

def normalizeBalances (mb sb : Nat) (standbyKeys : List String)
    (nodeMap : List (String × FlareNode)) : List (String × FlareNode) :=
  nodeMap.map (fun kv =>
    (kv.1, normalizeBalanceEntry mb sb (standbyKeys.contains kv.1) kv.2))

/-- Normalization preserves role and partition (balance-only rewrite). -/
theorem normalizeBalanceEntry_role (mb sb : Nat) (st : Bool) (n : FlareNode) :
    (normalizeBalanceEntry mb sb st n).role = n.role := by
  unfold normalizeBalanceEntry
  split
  · rfl
  · split
    · cases h : n.role <;> simp [h]
    · cases h : n.role <;> simp [h]

theorem normalizeBalanceEntry_partition (mb sb : Nat) (st : Bool) (n : FlareNode) :
    (normalizeBalanceEntry mb sb st n).partition = n.partition := by
  unfold normalizeBalanceEntry
  split
  · rfl
  · split
    · cases h : n.role <;> simp [h]
    · cases h : n.role <;> simp [h]

/-- A Down entry is untouched by normalization (see the def's comment). -/
theorem normalizeBalanceEntry_down (mb sb : Nat) (st : Bool) (n : FlareNode)
    (h : n.state = FlareState.Down) : normalizeBalanceEntry mb sb st n = n := by
  unfold normalizeBalanceEntry
  rw [if_pos (by rw [h]; rfl)]

/-- Per-key merge of the FSM's computed state (`ucs`) onto the live state
    (`current`). Lives in the pure layer (rather than Main) so its safety
    properties can be machine-checked.

    The FSM reconcile loop snapshots the live ref, computes `ucs` purely, then
    commits it back while the TCP server mutates the SAME ref on every
    `node add` / `node state ready`. A blind full-state replace would revert a
    TCP-driven Prepare→Active completion, so we merge per key:
    - role / partition / assignment: `ucs` wins — the FSM legitimately owns
      failover demotions and proxy→master/slave assignments.
    - state: `ucs` wins, EXCEPT when `current` has the SAME role, is `Active`,
      and `ucs` is `Prepare`: that is the TCP-driven Prepare→Active completion
      the FSM has not observed yet; keep `Active`.
    - keys only in `current` (nodes registered after the snapshot) are carried
      forward so no registration is lost.

    Finally `demoteDuplicateMasters` repairs the one inconsistency the merge
    itself can create — the FSM and the TCP fast path each assigning a
    different Master to the same partition (FSM entries come first, so the
    FSM's choice survives) — and the partitionMap is rebuilt from the merged
    nodeMap (single source of truth).

    Merge rule for a single `ucs` entry (see `mergeClusterState`): keep the
    FSM's value except for the one TCP-driven Prepare→Active completion. A
    top-level def (not an inline lambda) so the preservation lemmas below can
    reason about it directly. -/
def mergeNodeEntry (current : FlareClusterState) (key : String) (ucsNode : FlareNode)
    : FlareNode :=
  match current.nodeMap.lookup key with
  | some curNode =>
    -- A LIVE entry carrying a newer registration epoch was (re-)registered
    -- over TCP AFTER the FSM snapshotted: the FSM's opinion about this key
    -- is stale in its entirety, so the live entry wins wholesale. Without
    -- this, every commit resurrected ghost Master/Slave roles over a fresh
    -- Proxy re-registration (root cause of the pvc-data-survival data-loss
    -- churn). Ties (the common case: no re-registration happened) keep the
    -- established rules: FSM owns roles, TCP-driven Prepare→Active sticks.
    if curNode.regEpoch > ucsNode.regEpoch then
      -- Carve-out: let the FSM SEAT AN UNASSIGNED PROXY AS A SLAVE even when
      -- the live entry is newer. A freshly re-registered pod re-registers as
      -- Proxy with a bumped epoch every reconnect, so the strict rule above
      -- discarded the FSM's Slave assignment on every tick — and because the
      -- committed entry stayed Proxy/-1, flared kept reconnecting and
      -- re-bumping the epoch: a self-reinforcing wedge (observed live: a
      -- 1p×2r cluster ran 14h with its second node stuck Proxy after a roll,
      -- version pinned, no broadcasts; only an operator restart — which
      -- resets the non-serialized epochs to 0 — healed it). Seating a Slave
      -- is data-safe (Prepare → reconstructs from the master) and never
      -- mints a Master, so the ghost-master protection this guard exists for
      -- is untouched: a stale ucs MASTER still loses to the live entry.
      if curNode.role == FlareRole.Proxy && curNode.partition < 0
         && ucsNode.role == FlareRole.Slave then
        { curNode with role := FlareRole.Slave, state := FlareState.Prepare,
                       partition := ucsNode.partition, balance := 0 }
      else
        curNode
    else if curNode.role == ucsNode.role
       && curNode.state == FlareState.Active
       && ucsNode.state == FlareState.Prepare then
      { ucsNode with state := FlareState.Active }
    else
      ucsNode
  | none => ucsNode

/-- The `ucs` entries after the per-key merge. -/
def mergedUcsEntries (current ucs : FlareClusterState) : List (String × FlareNode) :=
  ucs.nodeMap.map fun kv => (kv.1, mergeNodeEntry current kv.1 kv.2)

/-- Entries only present on the live ref (nodes registered after the FSM's
    snapshot); carried forward so no registration is lost. -/
def currentOnlyEntries (current ucs : FlareClusterState) : List (String × FlareNode) :=
  current.nodeMap.filter (fun kv => !(ucs.nodeMap.map Prod.fst).contains kv.1)

def mergeClusterState (current ucs : FlareClusterState)
    (mb : Nat := 100) (sb : Nat := 0) (standbyKeys : List String := [])
    : FlareClusterState :=
  let combined := normalizeBalances mb sb standbyKeys (demoteDuplicateMasters
    (mergedUcsEntries current ucs ++ currentOnlyEntries current ucs))
  ({ ucs with
      nodeMap := combined
      nodeMapVersion := current.nodeMapVersion + 1 }).rebuildPartitionMap

/-! ## General safety of the duplicate-master repair

These are GENERAL theorems over ARBITRARY node maps — not `decide` checks of
concrete scenarios. Together they machine-check the split-brain repair at the
state-commit boundary: no matter what the FSM and the TCP server each wrote,
the node map that `mergeClusterState` commits can never contain two Masters
for the same partition. -/

/-- Count the Masters assigned to partition `p`. -/
def countMastersFor (p : Int) (l : List (String × FlareNode)) : Nat :=
  (l.filter (fun kv => kv.2.role == FlareRole.Master && kv.2.partition == p)).length

/-- `countMastersFor` over a cons: the head contributes 1 exactly when it is
    a Master of partition `p`. -/
theorem countMastersFor_cons (p : Int) (key : String) (node : FlareNode)
    (l : List (String × FlareNode)) :
    countMastersFor p ((key, node) :: l) =
      (if node.role == FlareRole.Master && node.partition == p
       then countMastersFor p l + 1 else countMastersFor p l) := by
  simp only [countMastersFor, List.filter_cons]
  split
  · simp
  · rfl

/-- Balance normalization does not change the per-partition Master count —
    the safety corollary below composes through it unchanged. -/
theorem countMastersFor_normalizeBalances (mb sb : Nat) (sk : List String) (p : Int)
    (l : List (String × FlareNode)) :
    countMastersFor p (normalizeBalances mb sb sk l) = countMastersFor p l := by
  induction l with
  | nil => rfl
  | cons kv rest ih =>
    obtain ⟨key, node⟩ := kv
    simp only [normalizeBalances, List.map_cons]
    rw [countMastersFor_cons, countMastersFor_cons,
        normalizeBalanceEntry_role, normalizeBalanceEntry_partition]
    simp only [normalizeBalances] at ih
    rw [ih]

/-- Normalization keeps the key list verbatim. -/
theorem normalizeBalances_keys (mb sb : Nat) (sk : List String)
    (l : List (String × FlareNode)) :
    (normalizeBalances mb sb sk l).map Prod.fst = l.map Prod.fst := by
  induction l with
  | nil => rfl
  | cons kv rest ih =>
    simp only [normalizeBalances, List.map_cons] at *
    simp [ih]

/-- If partition `p` is already in `seen`, the worker never emits a Master
    for `p` (all further Masters of `p` are demoted). -/
theorem demoteDuplicateMastersGo_none (l : List (String × FlareNode))
    (seen : List Int) (p : Int) (h : seen.contains p = true) :
    countMastersFor p (demoteDuplicateMastersGo seen l) = 0 := by
  induction l generalizing seen with
  | nil => rfl
  | cons kv rest ih =>
    obtain ⟨key, node⟩ := kv
    simp only [demoteDuplicateMastersGo]
    split
    · rename_i hm
      split
      · -- duplicate Master: demoted to Proxy, contributes nothing
        have hproxy : (FlareRole.Proxy == FlareRole.Master) = false := rfl
        simp [countMastersFor_cons, hproxy]
        exact ih seen h
      · -- first Master of its partition: kept, but its partition ≠ p
        rename_i hc
        have hne : (node.partition == p) = false := by
          cases hb : node.partition == p with
          | false => rfl
          | true =>
            have heq : node.partition = p := eq_of_beq hb
            rw [heq] at hc
            rw [h] at hc
            exact absurd rfl hc
        simp [countMastersFor_cons, hne]
        exact ih (node.partition :: seen)
          (by simp [List.contains_cons]; exact Or.inr (by simpa using h))
    · rename_i hm
      have hm' : (node.role == FlareRole.Master) = false := by
        cases hb : node.role == FlareRole.Master with
        | false => rfl
        | true => exact absurd hb hm
      simp [countMastersFor_cons, hm']
      exact ih seen h

/-- MAIN GENERAL THEOREM (worker): for EVERY input list and every partition,
    the worker's output contains at most one Master. -/
theorem demoteDuplicateMastersGo_atMostOne (l : List (String × FlareNode))
    (seen : List Int) (p : Int) :
    countMastersFor p (demoteDuplicateMastersGo seen l) ≤ 1 := by
  induction l generalizing seen with
  | nil => simp [demoteDuplicateMastersGo, countMastersFor]
  | cons kv rest ih =>
    obtain ⟨key, node⟩ := kv
    simp only [demoteDuplicateMastersGo]
    split
    · rename_i hm
      split
      · -- duplicate Master: demoted, contributes nothing
        have hproxy : (FlareRole.Proxy == FlareRole.Master) = false := rfl
        simp [countMastersFor_cons, hproxy]
        exact ih seen
      · -- first Master of its partition: kept
        rename_i hc
        cases hp : node.partition == p with
        | false =>
          simp [countMastersFor_cons, hp]
          exact ih (node.partition :: seen)
        | true =>
          -- the kept Master IS for partition p: it contributes exactly 1,
          -- and with p now in `seen` the tail contributes 0.
          have heq : node.partition = p := eq_of_beq hp
          have hzero := demoteDuplicateMastersGo_none rest (node.partition :: seen) p
            (by simp [List.contains_cons, heq])
          simp [countMastersFor_cons, hm, hp, hzero]
    · rename_i hm
      have hm' : (node.role == FlareRole.Master) = false := by
        cases hb : node.role == FlareRole.Master with
        | false => rfl
        | true => exact absurd hb hm
      simp [countMastersFor_cons, hm']
      exact ih seen

/-- MAIN GENERAL THEOREM: `demoteDuplicateMasters` outputs at most one
    Master per partition for EVERY input. -/
theorem demoteDuplicateMasters_atMostOne (l : List (String × FlareNode)) (p : Int) :
    countMastersFor p (demoteDuplicateMasters l) ≤ 1 :=
  demoteDuplicateMastersGo_atMostOne l [] p

/-- COROLLARY: the node map committed by `mergeClusterState` can never
    contain two Masters for one partition — for ARBITRARY `current` and
    `ucs` states, i.e. regardless of how the FSM snapshot and the TCP
    server's live writes interleaved. -/
theorem mergeClusterState_atMostOneMaster (current ucs : FlareClusterState)
    (mb sb : Nat) (sk : List String) (p : Int) :
    countMastersFor p (mergeClusterState current ucs mb sb sk).nodeMap ≤ 1 := by
  unfold mergeClusterState
  show countMastersFor p (normalizeBalances mb sb sk (demoteDuplicateMasters _)) ≤ 1
  rw [countMastersFor_normalizeBalances]
  exact demoteDuplicateMasters_atMostOne _ p

/-- The repair never drops or reorders an entry: the key list is preserved
    verbatim. -/
theorem demoteDuplicateMastersGo_keys (l : List (String × FlareNode)) (seen : List Int) :
    (demoteDuplicateMastersGo seen l).map Prod.fst = l.map Prod.fst := by
  induction l generalizing seen with
  | nil => rfl
  | cons kv rest ih =>
    obtain ⟨key, node⟩ := kv
    simp only [demoteDuplicateMastersGo]
    split
    · split
      · simp [ih seen]
      · simp [ih (node.partition :: seen)]
    · simp [ih seen]

theorem demoteDuplicateMasters_keys (l : List (String × FlareNode)) :
    (demoteDuplicateMasters l).map Prod.fst = l.map Prod.fst :=
  demoteDuplicateMastersGo_keys l []

/-- Non-Master entries pass through the repair verbatim (the repair only
    ever touches Masters). -/
theorem demoteDuplicateMastersGo_nonmaster_mem (l : List (String × FlareNode))
    (seen : List Int) (k : String) (n : FlareNode)
    (hmem : (k, n) ∈ l) (hrole : (n.role == FlareRole.Master) = false) :
    (k, n) ∈ demoteDuplicateMastersGo seen l := by
  induction l generalizing seen with
  | nil => cases hmem
  | cons kv rest ih =>
    obtain ⟨key, node⟩ := kv
    simp only [demoteDuplicateMastersGo]
    rcases List.mem_cons.mp hmem with heq | htail
    · cases heq
      simp [hrole]
    · split
      · split
        · exact List.mem_cons_of_mem _ (ih seen htail)
        · exact List.mem_cons_of_mem _ (ih (node.partition :: seen) htail)
      · exact List.mem_cons_of_mem _ (ih seen htail)

/-- NO LOST REGISTRATION: every key present in either input state appears in
    the node map committed by the merge — a node registered on the live ref
    after the FSM snapshot, or present in the FSM's own output, is never
    dropped. General theorem over arbitrary states. -/
theorem mergeClusterState_preserves_keys (current ucs : FlareClusterState)
    (mb sb : Nat) (sk : List String) (k : String)
    (h : k ∈ ucs.nodeMap.map Prod.fst ∨ k ∈ current.nodeMap.map Prod.fst) :
    k ∈ (mergeClusterState current ucs mb sb sk).nodeMap.map Prod.fst := by
  have hkeys : (mergeClusterState current ucs mb sb sk).nodeMap.map Prod.fst
      = (mergedUcsEntries current ucs ++ currentOnlyEntries current ucs).map Prod.fst := by
    unfold mergeClusterState
    exact (normalizeBalances_keys _ _ _ _).trans (demoteDuplicateMasters_keys _)
  have hm : (mergedUcsEntries current ucs).map Prod.fst = ucs.nodeMap.map Prod.fst := by
    unfold mergedUcsEntries
    rw [List.map_map]
    exact List.map_congr_left (fun kv _ => rfl)
  rw [hkeys, List.map_append, List.mem_append]
  by_cases hin : k ∈ ucs.nodeMap.map Prod.fst
  · left; rw [hm]; exact hin
  · rcases h with hu | hc
    · exact absurd hu hin
    · right
      obtain ⟨kv, hkv, hfst⟩ := List.mem_map.mp hc
      refine List.mem_map.mpr ⟨kv, List.mem_filter.mpr ⟨hkv, ?_⟩, hfst⟩
      have hnotin : ¬ ((ucs.nodeMap.map Prod.fst).contains kv.1 = true) := by
        intro hcontains
        apply hin
        rw [← hfst]
        simpa using hcontains
      simpa using hnotin

/-- NO CORPSE RESURRECTION: a Down (failover-demoted) entry in the FSM state
    survives the merge verbatim — still Down — UNLESS a strictly newer
    registration for the same key exists on the live side (`regEpoch`
    hypothesis): a pod that re-registered after the snapshot legitimately
    supersedes its own corpse. The Prepare→Active preservation can only fire
    on a Prepare entry, and the duplicate-Master repair only touches
    Masters, so a Proxy/Down corpse is untouched by both. General theorem
    over arbitrary states. -/
theorem mergeClusterState_down_survives (current ucs : FlareClusterState)
    (mb sb : Nat) (sk : List String) (k : String) (n : FlareNode)
    (hmem : (k, n) ∈ ucs.nodeMap)
    (hrole : (n.role == FlareRole.Master) = false)
    (hdown : n.state = FlareState.Down)
    (hfresh : ∀ curNode, current.nodeMap.lookup k = some curNode →
      curNode.regEpoch ≤ n.regEpoch) :
    (k, n) ∈ (mergeClusterState current ucs mb sb sk).nodeMap := by
  have hentry : mergeNodeEntry current k n = n := by
    unfold mergeNodeEntry
    cases hl : current.nodeMap.lookup k with
    | none => rfl
    | some curNode =>
      have hle := hfresh curNode hl
      simp [hdown, show (FlareState.Down == FlareState.Prepare) = false from rfl,
        Nat.not_lt_of_le hle]
  have hmerged : (k, n) ∈ mergedUcsEntries current ucs := by
    have himg := List.mem_map_of_mem
      (f := fun kv => (kv.1, mergeNodeEntry current kv.1 kv.2)) hmem
    simpa [mergedUcsEntries, hentry] using himg
  have hcomb : (k, n) ∈ mergedUcsEntries current ucs ++ currentOnlyEntries current ucs :=
    List.mem_append_left _ hmerged
  unfold mergeClusterState
  have hd := demoteDuplicateMastersGo_nonmaster_mem _ [] k n hcomb hrole
  have hnorm : normalizeBalanceEntry mb sb (sk.contains k) n = n :=
    normalizeBalanceEntry_down mb sb (sk.contains k) n hdown
  have himg : (k, normalizeBalanceEntry mb sb (sk.contains k) n) ∈ normalizeBalances mb sb sk
      (demoteDuplicateMastersGo []
        (mergedUcsEntries current ucs ++ currentOnlyEntries current ucs)) :=
    List.mem_map_of_mem
      (f := fun kv => (kv.1, normalizeBalanceEntry mb sb (sk.contains kv.1) kv.2)) hd
  rw [hnorm] at himg
  exact himg

/-- Resolve spec.readBalance.standby selectors against this tick's pod list.
    podName matches the first DNS label of the node key (the STS ordinal name,
    stable across pod recreation); zone matches the podZones mapping. -/
def resolveStandbyKeys (rb : ReadBalanceSpec) (livePodKeys : List String)
    (podZones : List (String × String)) : List String :=
  if rb.standby.isEmpty then []
  else livePodKeys.filter fun key =>
    rb.standby.any fun sel =>
      (match sel.podName with
       | some pn => key == pn || (key.splitOn ".").head? == some pn
       | none => false)
      || (match sel.zone with
          | some z => podZones.lookup key == some z
          | none => false)

/-- Stable-reorder every partition's slave list so standby slaves come LAST.
    All promotion paths pick `slaves.head?`, so this makes standby nodes the
    promotion choice of last resort (availability still beats locality: with
    only standby slaves left, one IS promoted) without touching any promotion
    function or its safety proof — the nodeMap is untouched. -/
def deprioritizeStandbySlaves (standbyKeys : List String)
    (s : FlareClusterState) : FlareClusterState :=
  if standbyKeys.isEmpty then s
  else { s with partitionMap := s.partitionMap.map fun (idx, part) =>
    (idx, { part with slaves :=
      part.slaves.filter (fun k => !standbyKeys.contains k)
        ++ part.slaves.filter (fun k => standbyKeys.contains k) }) }

/-- The reorder never touches the node map (partitionMap only), so every
    nodeMap-level safety metric is trivially preserved. -/
theorem deprioritizeStandbySlaves_nodeMap (sk : List String)
    (s : FlareClusterState) :
    (deprioritizeStandbySlaves sk s).nodeMap = s.nodeMap := by
  unfold deprioritizeStandbySlaves
  split <;> rfl

/-- Pure dead-node detection (mirrors legacy `detectDeadNodes`, Main.lean:116-124).
    A node is dead only if its pod is gone AND it is a role/state that should be
    actively served. Excludes:
    - Proxy nodes: not yet assigned to a partition, nothing to fail over.
    - Down nodes: already demoted, re-flagging causes churn.
    - Prepare nodes: actively reconstructing (potentially a 100GB+ dataset). Their
      pod may briefly drop from the ready list; marking them dead would abort the
      reconstruction and trigger a needless rebalance. -/
def detectDeadNodesPure (state : FlareClusterState) (livePodKeys : List String)
    : List String :=
  state.nodeMap.filter (fun (key, node) =>
    !livePodKeys.contains key
    && node.role != FlareRole.Proxy
    && node.state != FlareState.Down
    && node.state != FlareState.Prepare) |>.map Prod.fst

/-- Pure draining-node detection: a node whose pod is Terminating
    (deletionTimestamp set) but STILL present+alive in the pod list, and still
    an authoritative Master or replica Slave. Unlike `detectDeadNodesPure` this
    fires while the pod is alive (inside the preStop window) so the operator can
    hand off gracefully — promote a replacement and demote this node to a live
    proxy — BEFORE flared exits, instead of only reacting once the pod vanishes.
    Already-Proxy or Down nodes are skipped (nothing to drain / idempotent). -/
def detectDrainingNodesPure (state : FlareClusterState) (terminatingKeys : List String)
    : List String :=
  state.nodeMap.filter (fun (key, node) =>
    terminatingKeys.contains key
    && node.role != FlareRole.Proxy
    && node.state != FlareState.Down) |>.map Prod.fst

/-- Pure proxy assignment (Main.lean:323-330).
    Assigns roles to any Proxy nodes using autoAssign.

    A node that was just demoted by failover has role=Proxy AND state=Down; it must
    NOT be picked back up as the new master (that would resurrect the dead node and
    flap forever). We only auto-assign Proxy nodes that are actually alive, so an
    open master slot is filled by a live registered node (the promoted replica),
    never by the corpse of the node that just failed. -/
def assignProxiesPure (state : FlareClusterState) (crd : FlareClusterView)
    (livePodKeys : List String) (zones : List (String × String) := [])
    (terminatingKeys : List String := []) : FlareClusterState :=
  state.nodeMap.foldl (init := state) fun currentState (nodeKey, node) =>
    if node.role == FlareRole.Proxy && node.state != FlareState.Down
        && !terminatingKeys.contains nodeKey then
      let (newState, _) := autoAssign currentState crd nodeKey node livePodKeys zones
      newState
    else
      currentState

/-- Refill a partition that has lost EVERY master entry. Total-partition
    restart re-registers every replica as a syncing Slave/Prepare (never
    Proxy — see the NodeAdd rejoin path in Reconciler.lean), so neither
    autoAssign (proxies only) nor failover (Down entries only) will ever
    refill the slot; without this pass the partition deadlocks: slaves in
    Prepare with no master to sync from.

    Candidate order, LIVE pods only (this is the information the TCP rejoin
    path lacked): an Active slave first — it is in sync, and preferring it
    is exactly the zombie guard (the restarted ex-master must resync, not
    resume) — otherwise the live node that most recently mastered the
    partition (lastMasterOf), i.e. the newest surviving copy on its PVC.
    Promotion is Master/Active: flared treats an Active designation as
    authoritative and skips reconstruction, so the local data keeps
    serving. -/
def promoteMasterlessPartition (state : FlareClusterState) (pIdx : Nat)
    (livePodKeys : List String) (standbyKeys : List String := []) : FlareClusterState :=
  if FlareOperator.Reconciler.hasMasterForPartition state pIdx then state
  else
    let isActiveSlave := fun ((key, n) : String × FlareNode) =>
      n.role == FlareRole.Slave && n.state == FlareState.Active
        && n.partition == Int.ofNat pIdx && livePodKeys.contains key
    let candidate :=
      -- standby slaves are the refill choice of LAST resort (availability
      -- still wins over locality when only standby copies survive).
      ((state.nodeMap.find? (fun kv => isActiveSlave kv && !standbyKeys.contains kv.1)).orElse
        (fun _ => state.nodeMap.find? isActiveSlave)).orElse
      (fun _ => state.nodeMap.find? (fun (key, n) =>
        n.lastMasterOf == Int.ofNat pIdx && n.state != FlareState.Down
          && livePodKeys.contains key))
    match candidate with
    | some kv =>
      state.addNode kv.1 { kv.2 with
        role := FlareRole.Master, state := FlareState.Active,
        partition := Int.ofNat pIdx, lastMasterOf := -1 }
    | none => state

/-- Run the masterless-partition refill over every partition of the CRD. -/
def promoteMasterlessPartitions (state : FlareClusterState) (crd : FlareClusterView)
    (livePodKeys : List String) (standbyKeys : List String := []) : FlareClusterState :=
  (List.range crd.spec.partitions).foldl
    (fun s pIdx => promoteMasterlessPartition s pIdx livePodKeys standbyKeys) state

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

/-- Extract the pod name (first DNS label) from a node's FQDN serverName.
    K8s Service selector values must be ≤63 chars, so the full FQDN can't be used
    (mirrors the legacy `extractPodName`, Main.lean:169-172). -/
def extractPodNamePure (fqdn : String) : String :=
  match fqdn.splitOn "." with
  | podName :: _ => podName
  | [] => fqdn

/-- Build the Service-selector patch effects for a reconciled cluster state.
    For each partition that has a current master, emit a `.PatchService` effect
    pointing the partition's client Service (`{crName}-{partition}`) at the master's
    pod. This is what actually re-routes client traffic after a failover/assignment;
    without it the Service keeps targeting the dead pod (mirrors the legacy
    `ensureServiceRouting`, Main.lean:174-189). -/
def servicePatchEffects (state : FlareClusterState) (crName : String)
    : List FlareEffect :=
  state.partitionMap.filterMap fun (idx, part) =>
    match part.master with
    | none => none
    | some masterKey =>
      match state.lookupNode masterKey with
      | none => none
      | some masterNode =>
        let svcName := s!"{crName}-{idx}"
        let podName := extractPodNamePure masterNode.serverName
        some (.PatchService svcName podName)

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
    | .PodListResponse pods zones terminating =>
      -- CRITICAL: Check grace period (Main.lean:355-359)
      if s.graceCycles > 0 then
        -- Still in startup grace period - skip dead node detection AND drain
        ({ s with reconcileStep := .AfterDetectDead,
                  livePodKeys := pods,
                  podZones := zones,
                  deadNodeKeys := [],
                  terminatingKeys := terminating,
                  drainNodeKeys := [],
                  standbyNodeKeys := match s.cachedCrd with
                    | some crd => resolveStandbyKeys crd.spec.readBalance pods zones
                    | none => [],
                  graceCycles := s.graceCycles - 1 }, none,
         [.Log s!"[flare-operator] grace period: {s.graceCycles - 1} cycles remaining"])
      else
        -- Grace period over - normal dead-node detection + graceful drain of
        -- any Terminating (deletionTimestamp) master/slave that is still alive.
        let deadKeys := detectDeadNodesPure clusterState pods
        let drainKeys := detectDrainingNodesPure clusterState terminating
        ({ s with reconcileStep := .AfterDetectDead,
                  livePodKeys := pods,
                  podZones := zones,
                  deadNodeKeys := deadKeys,
                  terminatingKeys := terminating,
                  drainNodeKeys := drainKeys,
                  standbyNodeKeys := match s.cachedCrd with
                    | some crd => resolveStandbyKeys crd.spec.readBalance pods zones
                    | none => [] }, none, [])
    | other =>
      ({ s with reconcileStep := .Error s!"unexpected response at AfterListPods: {repr other}" }, none, [])

  | .AfterDetectDead =>
    -- Blast Radius Circuit Breaker: Check if failure is too large (AZ-level)
    let totalNodes := clusterState.nodeMap.length
    let deadCount := s.deadNodeKeys.length

    -- Get circuit breaker config from CRD (default if not available)
    let breakerCfg := match s.cachedCrd with
      | some crd => crd.spec.circuitBreaker
      | none => {}  -- Use default config

    if deadCount == 0 then
      -- No failures - continue normally
      ({ s with reconcileStep := .AfterHandleFailover,
                failoverTriggered := false,
                updatedClusterState := some clusterState }, none, [])
    else
      -- Check circuit breaker
      let (nextStep, breakerEffects) := circuitBreakerDecision deadCount totalNodes breakerCfg s.wasTripped
      let allEffects := .Log s!"[flare-operator] detected {deadCount} dead nodes: {s.deadNodeKeys}" :: breakerEffects
      ({ s with reconcileStep := nextStep,
                failoverTriggered := (nextStep == .AfterHandleFailover),
                -- Tripped this pass (RecoveryRefill or EmergencyPaused): feed
                -- next cycle's hysteresis even when the pass ends in Done
                -- after a successful refill.
                breakerHeld := !(nextStep == .AfterHandleFailover) }, none, allEffects)

  | .AfterHandleFailover =>
    -- Apply failover logic if triggered. Use the promotion variant so a dead
    -- master's live slave is promoted (preserving the partition's data), not left
    -- for the empty recreated pod to grab. rebuildPartitionMap first so the
    -- promotion sees an accurate master/slave grouping.
    let afterFailover :=
      if s.failoverTriggered then
        handleFailoverWithPromotion
          (deprioritizeStandbySlaves s.standbyNodeKeys clusterState.rebuildPartitionMap)
          s.deadNodeKeys
      else
        clusterState
    -- Graceful drain: demote Terminating masters/slaves to a LIVE proxy and
    -- promote a replacement while the pod is still alive (preStop window), so
    -- flared forwards existing connections to the new master. Runs regardless of
    -- failover (a Terminating pod is still "live", so dead detection never fires
    -- for it). rebuildPartitionMap so the promotion sees post-failover grouping.
    let newState :=
      if s.drainNodeKeys.isEmpty then afterFailover
      else handleDrainWithPromotion
        (deprioritizeStandbySlaves s.standbyNodeKeys afterFailover.rebuildPartitionMap)
        s.drainNodeKeys
    -- Masters the drain guard kept (no promotable successor): the partition
    -- will lose its only data-bearing node at grace expiry and the operator
    -- CANNOT fix that — surface it as CRITICAL (log here, gauge via
    -- drainBlockedCount) so a human decides (trigger a final backup / accept
    -- the S3 rewind). Deletion itself is irreversible (deletionTimestamp).
    let blocked :=
      if s.drainNodeKeys.isEmpty then []
      else drainBlockedKeys newState s.drainNodeKeys
    let drainEffects :=
      if s.drainNodeKeys.isEmpty then []
      else [FlareEffect.Log s!"[flare-operator] graceful drain: demoting Terminating node(s) to live proxy + promoting replacement(s): {s.drainNodeKeys}"]
    let blockedEffects := blocked.map fun k =>
      FlareEffect.Log s!"[flare-operator] CRITICAL: draining master {k} has NO promotable successor — kept as master until its grace period expires; the partition then loses its only data-bearing node (tmpfs: rewind to last S3 backup on reseed). Operator cannot recover this. See RUNBOOK #drain-no-successor"
    ({ s with reconcileStep := .AfterAssignRoles,
              updatedClusterState := some newState,
              drainBlockedCount := blocked.length }, none, drainEffects ++ blockedEffects)

  | .AfterAssignRoles =>
    -- Assign proxy roles (Main.lean:323-330)
    match s.updatedClusterState, s.cachedCrd with
    | some state, some crd =>
      -- Exclude Terminating keys: a just-drained node is Proxy/Active and would
      -- otherwise be re-assigned a role here, undoing the drain (flapping).
      let stateWithProxies := assignProxiesPure state crd s.livePodKeys s.podZones s.terminatingKeys
      -- Refill partitions that lost every master to a total restart (all
      -- replicas re-registered as Slave/Prepare, so no proxy exists for
      -- autoAssign and no Down entry exists for failover).
      let stateWithMasters := promoteMasterlessPartitions stateWithProxies crd s.livePodKeys s.standbyNodeKeys
      -- Persistent-violation detection: a partition whose copies all sit in
      -- one zone survives spread constraints (they place pods, not roles).
      -- Phase 1 warns; automated repair (slave migration) is future work.
      let singleZone := FlareOperator.Reconciler.partitionsInSingleZone
        stateWithMasters crd.spec.partitions s.podZones
      let warnEffects := singleZone.map (fun p =>
        FlareEffect.Log s!"[flare-operator] WARNING: every copy of partition {p} is in one zone — a single-zone outage takes the whole partition")
      -- NOTE: the stuck-Prepare watchdog lives in the IO shell
      -- (prepareCyclesRef in Main.lean, --prepare-stuck-cycles): FSM state
      -- does not persist across ticks, so a counter here can never fire —
      -- an earlier version made exactly that mistake.
      -- Phase 2: repair a single-zone partition by swapping one of its
      -- slaves with a cross-zone donor (gated inside: steady state only,
      -- ≥2 slaves, donor's partition stays diverse). One swap per tick;
      -- the resulting Prepare pair blocks further repairs until it syncs.
      let (stateFinal, repairEffects) :=
        match FlareOperator.Reconciler.findZoneRepairSwap stateWithMasters
            crd.spec.partitions s.podZones with
        | some (sKey, dKey) =>
          (FlareOperator.Reconciler.applyZoneRepairSwap stateWithMasters sKey dKey,
           [FlareEffect.Log s!"[flare-operator] zone repair: swapping slaves {sKey} ↔ {dKey} (cross-zone resync via reconstruction)"])
        | none => (stateWithMasters, [])
      ({ s with reconcileStep := .AfterUpdateConfigMap,
                updatedClusterState := some stateFinal }, none,
       warnEffects ++ repairEffects)
    | _, _ =>
      ({ s with reconcileStep := .Error "missing cluster state or CRD at AfterAssignRoles" }, none, [])

  | .AfterUpdateConfigMap =>
    -- Emit ConfigMap update effect (Main.lean:325-327).
    -- Use serializeNodeMap (the inverse of fromNodeMapData) so the persisted
    -- {cr}-node-map ConfigMap is reloadable on operator restart. A previous
    -- version wrote `repr state.nodeMap`, which fromNodeMapData cannot parse —
    -- the operator would silently start with an empty topology after a restart.
    match s.updatedClusterState with
    | some state =>
      let configData := FlareClusterState.serializeNodeMap state
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
    -- ALWAYS patch services (K8s idempotency requirement).
    -- Emit a PatchService effect for each partition's current master so client
    -- Services are re-routed to the live master. Previously this step only issued
    -- the arg-less PatchService *request* (a no-op executor), so selectors were
    -- never updated and clients kept hitting the dead pod after a failover.
    let crName := (s.cachedCrd.bind (·.metadata.name)).getD "flare"
    let patchEffects :=
      match s.updatedClusterState with
      | some state => servicePatchEffects state crName
      | none => []
    ({ s with reconcileStep := .Done }, some .PatchService, patchEffects)

  | .RecoveryRefill =>
    -- Breaker is TRIPPED. The breaker pauses topology OPTIMIZATION (proxy
    -- assignment, zone repair) — it must NOT pause RECOVERY, or the system
    -- deadlocks against sync-gated readiness + OrderedReady StatefulSets:
    -- with failover fully paused a dead master's stale map entry still reads
    -- master/active, so a returning replica never turns Active (= Ready),
    -- the StatefulSet never recreates the NEXT dead pod, and the dead
    -- fraction can never fall below the reset threshold (observed live: the
    -- ghost-master entry also blinded both the refill and the probe's
    -- no-active-master limbo clause). Recovery here is exactly two
    -- data-safe moves, both with existing CLE lemmas:
    --   1. handleFailoverWithPromotion over the dead keys: mark corpses Down
    --      and promote a dead master's ACTIVE slave (the zombie guard keeps
    --      unsynced nodes ineligible).
    --   2. promoteMasterlessPartitions: seat a live returning candidate (an
    --      Active slave, else the lastMasterOf holder) on a partition with
    --      no master left at all.
    -- If neither move changes anything, park in the fully-inert
    -- EmergencyPaused terminal exactly as before.
    match s.cachedCrd with
    | some crd =>
      let afterFailover :=
        if s.deadNodeKeys.isEmpty then clusterState
        else handleFailoverWithPromotion clusterState.rebuildPartitionMap s.deadNodeKeys
      let recovered := promoteMasterlessPartitions afterFailover crd s.livePodKeys
      let refilled := (List.range crd.spec.partitions).filter (fun p =>
        !FlareOperator.Reconciler.hasMasterForPartition afterFailover p
          && FlareOperator.Reconciler.hasMasterForPartition recovered p)
      -- ALWAYS advance into the commit pipeline (ConfigMap → broadcast →
      -- services), even when this pass changed nothing: while tripped the
      -- cluster is not fully Active, and the rc21 commit-layer semantics
      -- deliberately keep rebroadcasting in that regime — re-registered
      -- nodes need the fresh map to leave their stale self-entry behind
      -- (observed live: a parked breaker starved a returning replica of
      -- broadcasts and its readiness probe judged against a Down corpse of
      -- itself for ~7 minutes until flared's periodic re-pull). The inert
      -- EmergencyPaused terminal remains for the manual hold
      -- (autoResetEnabled=false) and the no-CRD edge.
      let logEffects :=
        if refilled.isEmpty then []
        else [FlareEffect.Log s!"[flare-operator] breaker tripped: recovery refill promoted returning node(s) for partition(s) {refilled}; optimization stays paused"]
      ({ s with reconcileStep := .AfterUpdateConfigMap,
                updatedClusterState := some recovered }, none, logEffects)
    | none =>
      ({ s with reconcileStep := .EmergencyPaused }, none, [])

  | .EmergencyPaused =>
    -- Terminal FOR THIS RECONCILE PASS: no failover, no assignment, no
    -- effects while tripped (see emergencyPaused_inert below). Reached when
    -- the breaker is tripped AND the RecoveryRefill pass found nothing
    -- refillable (or the hold is manual: autoResetEnabled=false). The outer
    -- loop rebuilds the FSM from Init on the next 5s tick, so the breaker
    -- re-evaluates continuously and recovery resumes AUTOMATICALLY when
    -- the dead fraction falls below the threshold — no operator restart
    -- is needed (an earlier comment here claimed otherwise).
    (s, none, [])

  | .Done =>
    -- Terminal: stay in Done
    (s, none, [])

  | .Error _ =>
    -- Terminal: stay in Error (IO shell will log and restart on next tick)
    (s, none, [])

/-- While tripped, the FSM is INERT: no state change, no K8s request, no
    effects — the pause cannot itself cause churn. -/
theorem emergencyPaused_inert (resp : K8sResponse) (s : FlareReconcileState)
    (cs : FlareClusterState) (h : s.reconcileStep = .EmergencyPaused) :
    flareReconcileCore resp s cs = (s, none, []) := by
  unfold flareReconcileCore
  split <;> simp_all

-- ===========================================================================
-- Measure Function for Termination
-- ===========================================================================

/-- Measure on FlareReconcileStep for termination arguments.
    Strictly decreasing on non-terminal transitions. -/
def flareReconcileMeasure : FlareReconcileStep → Nat
  | .Init => 12
  | .AfterFetchCRD => 11
  | .AfterListPods => 10
  | .AfterDetectDead => 9
  | .RecoveryRefill => 8
  | .EmergencyPaused => 0
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
    | PodListResponse _ _ _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | PatchResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | NoResponse => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
  | AfterListPods =>
    cases resp with
    | PodListResponse pods zones terminating =>
      simp only [flareReconcileCore, h]
      split <;> (left; simp [flareReconcileMeasure])
    | CRDResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | PatchResponse _ => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
    | NoResponse => right; simp [flareReconcileCore, h, flareReconcileTerminalBool]
  | AfterDetectDead =>
    simp only [flareReconcileCore, h]
    split
    · left; simp [flareReconcileMeasure]  -- deadCount == 0
    · -- deadCount > 0, check circuit breaker decision
      have h_decision := circuitBreakerDecision_only_returns_emergency_or_failover
        s.deadNodeKeys.length cs.nodeMap.length
        (match s.cachedCrd with | some crd => crd.spec.circuitBreaker | none => {})
        s.wasTripped
      rcases h_decision with hd | hd | hd
      · simp [hd]; right; simp [flareReconcileTerminalBool]  -- EmergencyPaused
      · simp [hd]; left; simp [flareReconcileMeasure]  -- RecoveryRefill (8 < 9)
      · simp [hd]; left; simp [flareReconcileMeasure]  -- AfterHandleFailover (7 < 9)
  | RecoveryRefill =>
    -- Either parks in EmergencyPaused (terminal) or advances to
    -- AfterUpdateConfigMap (5 < 8) after a successful refill.
    simp only [flareReconcileCore, h]
    cases hc : s.cachedCrd with
    | none => right; simp [flareReconcileTerminalBool]
    | some crd =>
      repeat' split
      all_goals first
        | (left; simp [h, flareReconcileMeasure])
        | (right; simp [flareReconcileTerminalBool])
        | simp_all
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
  | EmergencyPaused => simp [h, flareReconcileTerminalBool] at hNT
  | Done => simp [h, flareReconcileTerminalBool] at hNT
  | Error _msg => simp [h, flareReconcileTerminalBool] at hNT

/-- Measure = 0 implies terminal. -/
theorem measure_zero_is_terminal (step : FlareReconcileStep) :
    flareReconcileMeasure step = 0 → flareReconcileTerminalBool step = true := by
  intro h
  cases step with
  | Done => rfl
  | Error _ => rfl
  | EmergencyPaused => rfl
  | Init => simp [flareReconcileMeasure] at h
  | AfterFetchCRD => simp [flareReconcileMeasure] at h
  | AfterListPods => simp [flareReconcileMeasure] at h
  | AfterDetectDead => simp [flareReconcileMeasure] at h
  | RecoveryRefill => simp [flareReconcileMeasure] at h
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
  | EmergencyPaused => simp [flareReconcileCore, h]
  | Init => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterFetchCRD => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterListPods => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterDetectDead => simp [h, flareReconcileTerminalBool] at hTerm
  | RecoveryRefill => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterHandleFailover => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterAssignRoles => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterUpdateConfigMap => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterHandleReplication => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterBroadcastTopology => simp [h, flareReconcileTerminalBool] at hTerm
  | AfterPatchService => simp [h, flareReconcileTerminalBool] at hTerm

-- ===========================================================================
-- Recovery-Refill Progress
-- ===========================================================================

/-- PROGRESS — the escape hatch that breaks the tripped-breaker ↔ sync-gated
    readiness deadlock: with a CRD cached, RecoveryRefill ALWAYS advances into
    the commit pipeline (mark-dead-Down + refill + broadcast), so a tripped
    breaker can never starve returning replicas of topology updates. Safety of
    the recovery moves is the existing CLE corpus (handleFailover_cle,
    promoteMasterlessPartitions_cle): a partition's master count never
    exceeds one. -/
theorem recoveryRefill_advances (resp : K8sResponse) (s : FlareReconcileState)
    (cs : FlareClusterState) (crd : FlareClusterView)
    (h : s.reconcileStep = .RecoveryRefill)
    (hcrd : s.cachedCrd = some crd) :
    (flareReconcileCore resp s cs).1.reconcileStep = .AfterUpdateConfigMap := by
  unfold flareReconcileCore
  simp only [h, hcrd]
  repeat' split
  all_goals simp_all

/-- Without a cached CRD there is nothing to recover against: park in the
    fully-inert EmergencyPaused terminal. -/
theorem recoveryRefill_parks_without_crd (resp : K8sResponse)
    (s : FlareReconcileState) (cs : FlareClusterState)
    (h : s.reconcileStep = .RecoveryRefill)
    (hnone : s.cachedCrd = none) :
    (flareReconcileCore resp s cs).1.reconcileStep = .EmergencyPaused := by
  unfold flareReconcileCore
  simp [h, hnone]

end FlareOperator.K8sReconciler
