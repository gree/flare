/-
  Main.lean - Flare Operator entry point
  Operator-as-Index: replaces flarei with a K8s-native operator

  Wires together:
  - K8s.Bridge: kubectl subprocess calls (CRD fetch, pod list, service patch, etc.)
  - Server.TcpServer: native TCP server for flarei text protocol
  - StateMachine.Reconciler: pure state transitions (verified)
  - Kubectl: low-level kubectl wrapper

  Reconcile loop (operatorLoop):
    1. Fetch CRD spec
    2. List live pods
    3. Detect dead nodes (pure comparison against stateRef)
    4. Handle failover (pure state transition + K8s service patches)
    5. Ensure service routing for all partitions
    6. Update ConfigMap for observability
    7. Sleep and repeat
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.K8s.Bridge
import FlareOperator.Flare.Protocol
import FlareOperator.StateMachine.Reconciler
import FlareOperator.Kubectl
import FlareOperator.Server.TcpServer

namespace FlareOperator

open FlareOperator.K8s
open FlareOperator.K8s.Bridge
open FlareOperator.Flare
open FlareOperator.Reconciler
open FlareOperator.Kubectl
open FlareOperator.Server

-- ===========================================================================
-- CLI Argument Parsing
-- ===========================================================================

/-- Parse CLI arguments. Returns (namespace, port, reconcileInterval, clusterName). -/
private def parseArgs (args : List String) : String × UInt16 × Nat × Option String :=
  let rec go (args : List String) (ns : String) (port : UInt16) (interval : Nat)
      (clusterName : Option String) : String × UInt16 × Nat × Option String :=
    match args with
    | [] => (ns, port, interval, clusterName)
    | "--namespace" :: v :: rest => go rest v port interval clusterName
    | "--port" :: v :: rest =>
      match v.toNat? with
      | some p => go rest ns p.toUInt16 interval clusterName
      | none => go rest ns port interval clusterName
    | "--reconcile-interval" :: v :: rest =>
      match v.toNat? with
      | some i => go rest ns port i clusterName
      | none => go rest ns port interval clusterName
    | "--cluster-name" :: v :: rest => go rest ns port interval (some v)
    | _ :: rest => go rest ns port interval clusterName
  go args "default" 12120 5 none

-- ===========================================================================
-- String helpers
-- ===========================================================================

/-- Check if needle is a substring of haystack. -/
private def containsSubstr (haystack needle : String) : Bool :=
  let hLen := haystack.length
  let nLen := needle.length
  if nLen > hLen then false
  else
    let rec go (i : Nat) (fuel : Nat) : Bool :=
      match fuel with
      | 0 => false
      | fuel + 1 =>
        if i + nLen > hLen then false
        else if (haystack.drop i).startsWith needle then true
        else go (i + 1) fuel
    go 0 (hLen + 1)

-- ===========================================================================
-- Dead Node Detection (pure)
-- ===========================================================================

/-- Detect dead nodes: nodes with an active role (Master/Slave) that are no longer
    in the ready pods list.  Proxy/Down nodes are already inactive and should not
    be re-detected — this prevents false positives during startup when pods have
    registered via TCP but are not yet visible in the K8s pods list. -/
private def detectDeadNodes (state : FlareClusterState) (pods : List PodInfo)
    : List String :=
  let liveKeys := liveNodeKeys pods
  state.nodeMap.filter (fun (key, node) =>
    !liveKeys.contains key && node.role != FlareRole.Proxy && node.state != FlareState.Down
  ) |>.map Prod.fst

-- ===========================================================================
-- Failover Handler (pure state + IO for K8s patches)
-- ===========================================================================

/-- Handle failover: mark dead nodes Down, promote a Slave if master died.
    Pure state transition — no K8s I/O.
    Returns (newState, log messages) so the IO caller can print them. -/
private def handleFailover (state : FlareClusterState) (deadKeys : List String)
    : FlareClusterState × List String :=
  deadKeys.foldl (fun (s, logs) key =>
    match s.lookupNode key with
    | none => (s, logs)
    | some node =>
      let downNode := { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1 }
      let s' := s.addNode key downNode
      -- If dead node was a Master, try to promote a Slave in the same partition
      if node.role == FlareRole.Master then
        let partIdx := node.partition
        match s'.partitionMap.find? (fun (idx, _) => Int.ofNat idx == partIdx) with
        | none => (s', logs ++ [s!"[RECONCILER] Master for P{partIdx} ({key}) is gone. No partition entry found."])
        | some (_, part) =>
          match part.slaves.head? with
          | none => (s', logs ++ [s!"[RECONCILER] Master for P{partIdx} ({key}) is gone. No Slave available for promotion."])
          | some slaveKey =>
            match s'.lookupNode slaveKey with
            | none => (s', logs ++ [s!"[RECONCILER] Master for P{partIdx} ({key}) is gone. Slave {slaveKey} not found in nodeMap."])
            | some slaveNode =>
              let promoted := { slaveNode with role := FlareRole.Master, state := FlareState.Active, balance := 100 }
              let newPart := { part with master := some slaveKey, slaves := part.slaves.tail }
              let s'' := (s'.addNode slaveKey promoted).setPartition partIdx.toNat newPart
              (s'', logs ++ [s!"[RECONCILER] Master for P{partIdx} ({key}) is gone. Promoting Slave {slaveKey} to Master."])
      else (s', logs)
  ) (state, [])

-- ===========================================================================
-- Service Routing
-- ===========================================================================

/-- Ensure K8s Service selectors point to the current Master for each partition. -/
private def ensureServiceRouting (state : FlareClusterState) (crName ns : String)
    : IO Unit := do
  for (_, part) in state.partitionMap do
    match part.master with
    | none => pure ()
    | some masterKey =>
      match state.lookupNode masterKey with
      | none => pure ()
      | some masterNode =>
        let svcName := s!"{crName}-{masterNode.partition}"
        match ← patchClientServiceSelector svcName ns masterNode.serverName with
        | .error e =>
          IO.eprintln s!"[flare-operator] warning: failed to patch service {svcName}: {e}"
        | .ok () => pure ()

-- ===========================================================================
-- ConfigMap Observability
-- ===========================================================================

/-- Serialize the current node map to a string for ConfigMap storage. -/
private def serializeNodeMap (state : FlareClusterState) : String :=
  let lines := state.nodeMap.map fun (key, node) =>
    s!"{key} role={node.role.toNat} state={node.state.toNat} partition={node.partition}"
  "\n".intercalate lines

/-- Update the ConfigMap with the current cluster state for observability. -/
private def updateObservabilityConfigMap (state : FlareClusterState) (crName ns : String)
    : IO Unit := do
  let cmName := s!"{crName}-node-map"
  let data := serializeNodeMap state
  match ← updateFlaredConfigMap cmName ns data with
  | .error e =>
    IO.eprintln s!"[flare-operator] warning: failed to update configmap: {e}"
  | .ok () => pure ()

-- ===========================================================================
-- Lag Detection
-- ===========================================================================

/-- Check for severely lagging slave pods and force-restart them.
    A slave is considered lagging if it is registered but in Down state
    and still present in the ready pods list (zombie). -/
private def detectAndRestartLaggingPods (state : FlareClusterState) (pods : List PodInfo)
    (ns : String) : IO Unit := do
  let readyKeys := liveNodeKeys pods
  for (key, node) in state.nodeMap do
    -- If node is Down but still in the ready pods list, it's a zombie — force restart
    if node.state == FlareState.Down && readyKeys.contains key then
      -- Find the pod name from PodInfo list
      match pods.find? (fun p => p.toNodeKey == key) with
      | none => pure ()
      | some podInfo =>
        IO.eprintln s!"[flare-operator] force-restarting lagging pod {podInfo.name} (key={key})"
        match ← deletePod podInfo.name ns with
        | .error e =>
          IO.eprintln s!"[flare-operator] warning: failed to delete pod {podInfo.name}: {e}"
        | .ok () => pure ()

-- ===========================================================================
-- Cluster Replication (Blue/Green Migration)
-- ===========================================================================

/-- Handle cluster replication state machine.
    Manages the duplicate → forward mode transition autonomously. -/
private def handleClusterReplication
    (crd : FlareClusterView) (pods : List PodInfo)
    (migrationRef : IO.Ref MigrationPhase) (crName ns : String) : IO Unit := do
  let repl := crd.spec.clusterReplication
  if !repl.enabled then
    -- If replication was active but now disabled, clear config and reset
    let phase ← migrationRef.get
    if phase != .None then
      migrationRef.set .None
      match ← patchFlareClusterStatus crName ns .None with
      | .error e => IO.eprintln s!"[flare-operator] warning: failed to reset migrationPhase: {e}"
      | .ok () => pure ()
      IO.eprintln s!"[TRACE] ClusterReplication: {phase.toString}->None | Reason: replication disabled"
    return

  let phase ← migrationRef.get
  match phase with
  | .None =>
    -- Start replication: write config with mode=duplicate, SIGHUP, set Dumping
    match ← updateFlaredReplicationConfig crName ns repl with
    | .error e =>
      IO.eprintln s!"[flare-operator] warning: failed to write replication config: {e}"
      return
    | .ok () => pure ()
    sendSighupToPods crName ns
    migrationRef.set .Dumping
    match ← patchFlareClusterStatus crName ns .Dumping with
    | .error e => IO.eprintln s!"[flare-operator] warning: failed to patch status: {e}"
    | .ok () => pure ()
    IO.eprintln s!"[TRACE] ClusterReplication: None->Dumping | Reason: replication enabled (mode=duplicate)"

  | .Dumping =>
    -- Monitor: query all ready pods for dump_replication thread status
    -- (only masters actually run dump_replication threads; checking all is safe)
    let readyPods := pods.filter fun p => p.ready
    let mut dumpRunning := false
    for pod in readyPods do
      match ← queryPodStats pod.name ns "stats threads" with
      | .error _ => dumpRunning := true  -- assume still running on error
      | .ok output =>
        if containsSubstr output "dump_replication" then
          IO.eprintln s!"[TRACE] ClusterReplication: Dumping | dump_replication still running on {pod.name}"
          dumpRunning := true
    if !dumpRunning then
      -- Dump complete → transition to forward mode
      let forwardRepl := { repl with mode := "forward" }
      match ← updateFlaredReplicationConfig crName ns forwardRepl with
      | .error e =>
        IO.eprintln s!"[flare-operator] warning: failed to update replication config to forward: {e}"
        return
      | .ok () => pure ()
      sendSighupToPods crName ns
      migrationRef.set .Forwarding
      match ← patchFlareClusterStatus crName ns .Forwarding with
      | .error e => IO.eprintln s!"[flare-operator] warning: failed to patch status: {e}"
      | .ok () => pure ()
      IO.eprintln s!"[TRACE] ClusterReplication: Dumping->Forwarding | Reason: all dump_replication threads complete"

  | .Forwarding =>
    -- Steady state: forward mode active, nothing to do
    pure ()

-- ===========================================================================
-- Main Reconcile Loop
-- ===========================================================================

/-- Single iteration of the operator reconcile loop.
    Implements the K8s reconcile pattern:
    fetch CRD → list pods → detect dead → failover → route services → update ConfigMap
    The graceCyclesRef counts down startup grace cycles where dead detection is skipped,
    giving pods time to register via TCP and appear in the K8s ready list. -/
private def reconcileOnce (stateRef : IO.Ref FlareClusterState) (crdRef : IO.Ref FlareClusterView)
    (migrationRef : IO.Ref MigrationPhase) (graceCyclesRef : IO.Ref Nat)
    (crName ns : String) : IO Unit := do
  -- 1. Fetch latest CRD spec
  match ← getFlareClusterCRD crName ns with
  | .error e =>
    IO.eprintln s!"[flare-operator] warning: failed to fetch CRD: {e}"
  | .ok crd =>
    crdRef.set crd

  -- 2. List live pods (typed PodInfo with readiness)
  let pods ← Bridge.listFlaredPods crName ns

  -- 3. Detect dead nodes (pure) — skipped during startup grace period
  let graceCycles ← graceCyclesRef.get
  let state ← stateRef.get
  if graceCycles > 0 then
    graceCyclesRef.set (graceCycles - 1)
    IO.eprintln s!"[flare-operator] startup grace period: {graceCycles} cycles remaining, skipping dead detection"
    -- Still ensure service routing during grace period
    let state := state.rebuildPartitionMap
    ensureServiceRouting state crName ns
  else
    let deadKeys := detectDeadNodes state pods

    -- 4. Handle failover (pure state transition)
    if !deadKeys.isEmpty then
      IO.eprintln s!"[flare-operator] detected {deadKeys.length} dead node(s): {deadKeys}"
      IO.eprintln s!"[TRACE] DeadDetection: found {deadKeys.length} dead nodes: {deadKeys}"
      -- Before failover, rebuild partitionMap from nodeMap (single source of truth)
      let state := state.rebuildPartitionMap
      let (newState, failoverLogs) := handleFailover state deadKeys
      for msg in failoverLogs do
        IO.eprintln msg
      stateRef.set newState
      IO.eprintln s!"[TRACE] Failover: processed {deadKeys.length} dead nodes, {failoverLogs.length} actions taken"

      -- 5. Patch K8s Service selectors for failover
      ensureServiceRouting newState crName ns
    else
      -- 5b. Ensure service routing even when no failover (idempotent)
      let state := state.rebuildPartitionMap
      ensureServiceRouting state crName ns

  -- 6. Update ConfigMap for observability
  let currentState ← stateRef.get
  updateObservabilityConfigMap currentState crName ns

  -- 7. Detect and restart lagging/zombie pods (disabled: too aggressive during startup)
  -- detectAndRestartLaggingPods currentState pods ns

  -- 8. Handle cluster replication migration
  let crd ← crdRef.get
  handleClusterReplication crd pods migrationRef crName ns

-- ===========================================================================
-- Leader Election Helpers
-- ===========================================================================

private def leaseDurationSeconds : Nat := 15

private def getHostname : IO String := do
  let result ← IO.Process.output { cmd := "hostname", args := #[] }
  return result.stdout.trim

/-- Try to acquire or renew the leader lease.
    Returns true if this instance is (or became) the leader. -/
private def tryAcquireOrRenew (leaseName ns identity : String) : IO Bool := do
  match ← getLease leaseName ns with
  | .error _ =>
    -- Lease not found or transient error. Try to create.
    match ← createLease leaseName ns identity leaseDurationSeconds with
    | .ok () => return true
    | .error _ => return false
  | .ok lease =>
    if lease.holderIdentity == identity then
      -- We hold it, renew
      match ← renewLease leaseName ns identity with
      | .ok () => return true
      | .error _ => return false
    else if lease.expired then
      -- Expired, try to take over
      match ← acquireLease leaseName ns identity lease.holderIdentity leaseDurationSeconds with
      | .ok () => return true
      | .error _ => return false
    else
      return false  -- another pod holds a valid lease

-- ===========================================================================
-- Entry Point
-- ===========================================================================

/-- Main entry point. Two-phase leader election:
    Phase 1 (follower): Try to acquire the lease, completely passive.
    Phase 2 (leader): Run TCP server + reconcile loop, renew lease each iteration. -/
def main (args : List String) : IO Unit := do
  let (ns, port, interval, clusterNameArg) := parseArgs args
  let identity ← getHostname

  IO.eprintln s!"[flare-operator] starting (namespace={ns}, port={port}, interval={interval}s, identity={identity})"

  -- Discover FlareCluster CRs (or use --cluster-name if provided)
  let crName ← do
    match clusterNameArg with
    | some name =>
      IO.eprintln s!"[flare-operator] managing FlareCluster '{name}' (from --cluster-name)"
      pure name
    | none =>
      match ← listFlareClusters ns with
      | .error e =>
        IO.eprintln s!"[flare-operator] warning: could not list FlareClusters: {e}"
        pure "flare"
      | .ok [] =>
        IO.eprintln s!"[flare-operator] no FlareCluster CR found, using default name 'flare'"
        pure "flare"
      | .ok ((name, _) :: _) =>
        IO.eprintln s!"[flare-operator] managing FlareCluster '{name}'"
        pure name

  let leaseName := s!"{crName}-operator-lease"

  -- ═══════════════════════════════════════════════════════════════════════
  -- PHASE 1: Follower loop — try to become leader
  -- ═══════════════════════════════════════════════════════════════════════
  IO.eprintln s!"[flare-operator] phase 1: attempting to acquire lease '{leaseName}'"
  let mut isLeader := false
  while !isLeader do
    isLeader ← tryAcquireOrRenew leaseName ns identity
    if !isLeader then
      IO.sleep (interval * 1000).toUInt32

  IO.eprintln s!"[flare-operator] phase 2: acquired lease, entering leader mode"

  -- ═══════════════════════════════════════════════════════════════════════
  -- PHASE 2: Leader mode — run TCP server + reconcile loop
  -- ═══════════════════════════════════════════════════════════════════════

  -- Initialize shared state
  let stateRef ← IO.mkRef FlareClusterState.default

  -- Try to load persisted state from ConfigMap
  let cmName := s!"{crName}-node-map"
  match ← readFlaredConfigMap cmName ns with
  | .error _ => IO.eprintln s!"[flare-operator] no persisted state found, starting fresh"
  | .ok data =>
    if data.trim != "" then
      let loaded := FlareClusterState.fromNodeMapData data
      let loaded := loaded.rebuildPartitionMap
      stateRef.set loaded
      IO.eprintln s!"[flare-operator] loaded {loaded.nodeMap.length} nodes from ConfigMap"
  let crdRef ← IO.mkRef ({
    metadata := { name := some crName, «namespace» := some ns }
    spec := { partitions := 1, replicas := 1 }
  } : FlareClusterView)
  let migrationRef ← IO.mkRef MigrationPhase.None

  -- Startup grace period: skip dead node detection for the first 6 reconcile cycles
  -- (6 × 5s = 30s) to let all pods register via TCP and appear in the K8s ready list.
  -- This prevents the race condition where nodes register via `node add` and get
  -- assigned Master/Slave roles before their pods appear in `kubectl get pods`.
  let graceCyclesRef ← IO.mkRef (6 : Nat)

  -- Start TCP server in background (using Server.TcpServer)
  let _ ← IO.asTask (prio := .default) do
    try
      startServerFromRefs port stateRef crdRef
    catch e =>
      IO.eprintln s!"[flare-operator] TCP server error: {e}"

  -- Reconcile loop with lease renewal
  while true do
    -- Renew lease each iteration
    let renewed ← tryAcquireOrRenew leaseName ns identity
    if !renewed then
      IO.eprintln s!"[flare-operator] LOST LEASE -- exiting"
      throw (IO.userError "lease lost")

    try
      reconcileOnce stateRef crdRef migrationRef graceCyclesRef crName ns
    catch e =>
      IO.eprintln s!"[flare-operator] reconcile error: {e}"
    IO.sleep (interval * 1000).toUInt32

end FlareOperator

def main (args : List String) : IO Unit :=
  FlareOperator.main args
