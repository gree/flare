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
import FlareOperator.StateMachine.K8sReconciler
import FlareOperator.Kubectl
import FlareOperator.Server.TcpServer
import FlareOperator.Server.TopologyBroadcast
import FlareOperator.Metrics.Prometheus
import FlareOperator.Metrics.HttpServer
import FlareOperator.Health.HealthCheck

namespace FlareOperator

open FlareOperator.K8s
open FlareOperator.K8s.Bridge
open FlareOperator.Flare
open FlareOperator.Reconciler
open FlareOperator.Kubectl
open FlareOperator.Server
open FlareOperator.Metrics.Prometheus
open FlareOperator.Metrics.HttpServer
open FlareOperator.Health.HealthCheck

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

/-- Detect dead nodes: nodes in the nodeMap whose pod has completely disappeared
    from the K8s pod list.

    **Production design considerations**:

    The following nodes are EXCLUDED from dead detection:
    - Proxy / Down: already inactive; re-detecting them causes noise.
    - Prepare: actively reconstructing data from a peer.  A 100 GB dataset can
      take hours to reconstruct and the node stays in Prepare the whole time.
      Marking it dead during reconstruction would trigger an unnecessary
      failover and waste the work already done.  If the pod genuinely crashes,
      K8s will restart it and it will re-register via `node add`.

    Only Active Masters and Active Slaves are eligible for dead detection,
    because losing one of those affects data availability.

    The `pods` list comes from `kubectl get pods -l app=flare,cluster=<name>`
    and includes ALL pods (Ready or not).  A pod in CrashLoopBackOff still
    appears in this list, so its node key stays in `liveKeys` and the node is
    not prematurely marked dead.  Only a pod that has been completely deleted
    (e.g., StatefulSet scale-down, manual delete, or node eviction) disappears
    from the list and triggers dead detection.

    See ROCKSDB_REPLICATION.md §S1 (slave recovery) and §S4 (zombie master)
    for the interaction between dead detection and replication recovery. -/
private def detectDeadNodes (state : FlareClusterState) (pods : List PodInfo)
    : List String :=
  let liveKeys := liveNodeKeys pods
  state.nodeMap.filter (fun (key, node) =>
    !liveKeys.contains key
    && node.role != FlareRole.Proxy
    && node.state != FlareState.Down
    && node.state != FlareState.Prepare
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
      let roleName := match node.role with | .Master => "Master" | .Slave => "Slave" | .Proxy => "Proxy"
      let stateName := match node.state with | .Active => "Active" | .Prepare => "Prepare" | .Down => "Down" | .Ready => "Ready"
      let downNode := { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1 }
      let s' := s.addNode key downNode
      let logs := logs ++ [s!"[NodeState] {key}: {roleName}/{stateName} P{node.partition} → Proxy/Down (dead)"]
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

/-- Extract pod name from FQDN (e.g., "pod-0.svc.ns.cluster.local" -> "pod-0").
    Kubernetes selector values must be ≤63 chars, so we can't use full FQDNs. -/
private def extractPodName (fqdn : String) : String :=
  match fqdn.splitOn "." with
  | podName :: _ => podName
  | [] => fqdn

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
        let podName := extractPodName masterNode.serverName
        match ← patchClientServiceSelector svcName ns podName with
        | .error e =>
          IO.eprintln s!"[flare-operator] warning: failed to patch service {svcName}: {e}"
        | .ok () => pure ()

-- ===========================================================================
-- ConfigMap Observability
-- ===========================================================================

/-- Serialize the current node map to a string for ConfigMap storage.
    Delegates to the shared `FlareClusterState.serializeNodeMap` (inverse of
    `fromNodeMapData`) so the reconcile loop and the restart-reload path can never
    drift into incompatible formats. -/
private def serializeNodeMap (state : FlareClusterState) : String :=
  FlareClusterState.serializeNodeMap state

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

/-- Reconcile `spec.rocksdb` into the flared ConfigMap.

    Runs unconditionally on every reconcile cycle, but is a fast no-op in two
    cases: (1) the CR has no rocksdb fields set, or (2) the ConfigMap already
    contains exactly the lines we would write. Only on a genuine change do we
    re-apply and SIGHUP the pods so flared re-reads `extra.conf`.

    This handler is intentionally independent of cluster-replication: a user
    who wants rocksdb tuning but has not enabled blue/green migration still
    needs these lines written. When cluster-replication IS enabled, the
    `handleClusterReplication` path below renders a combined extra.conf
    containing both sections, so the two handlers never fight. -/
private def handleRocksdbConfig (crd : FlareClusterView) (crName ns : String) : IO Unit := do
  let rocksdb := crd.spec.rocksdb
  IO.eprintln s!"[DEBUG] handleRocksdbConfig: hasAny={rocksdb.hasAny} walTtl={rocksdb.walTtlSeconds} walSize={rocksdb.walSizeLimitMb} sync={rocksdb.syncWrites}"
  if !rocksdb.hasAny then
    return  -- nothing to do; leave any existing ConfigMap alone
  if crd.spec.clusterReplication.enabled then
    return  -- handleClusterReplication will render both sections together
  let desired := renderFlaredExtraConf rocksdb none
  -- Skip if the ConfigMap already has exactly this content (avoid SIGHUP storm).
  match ← readFlaredExtraConf crName ns with
  | .ok current =>
    if current == desired then
      return
  | .error _ =>
    pure ()  -- missing or unreadable; fall through and (re)create it
  IO.eprintln s!"[flare-operator] reconciling rocksdb config for {crName}"
  match ← updateFlaredRocksdbConfig crName ns rocksdb with
  | .error e =>
    IO.eprintln s!"[flare-operator] ERROR: failed to write rocksdb config: {e}"
  | .ok () =>
    sendSighupToPods crName ns
    IO.eprintln s!"[TRACE] RocksdbConfig: applied {rocksdb.toExtraConf.length} bytes, SIGHUP sent"

/-- Handle cluster replication state machine.
    Manages the duplicate → forward mode transition autonomously. -/
private def handleClusterReplication
    (crd : FlareClusterView) (pods : List PodInfo)
    (migrationRef : IO.Ref MigrationPhase) (crName ns : String) : IO Unit := do
  let repl := crd.spec.clusterReplication
  let rocksdb := crd.spec.rocksdb
  IO.eprintln s!"[DEBUG] handleClusterReplication: enabled={repl.enabled}"
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
  IO.eprintln s!"[DEBUG] handleClusterReplication: current phase={phase.toString}"
  match phase with
  | .None =>
    -- Start replication: write config with mode=duplicate, SIGHUP, set Dumping
    IO.eprintln s!"[DEBUG] handleClusterReplication: calling updateFlaredReplicationConfig"
    match ← updateFlaredReplicationConfig crName ns repl rocksdb with
    | .error e =>
      IO.eprintln s!"[flare-operator] ERROR: failed to write replication config: {e}"
      return
    | .ok () =>
      IO.eprintln s!"[DEBUG] handleClusterReplication: ConfigMap updated successfully"
    sendSighupToPods crName ns
    migrationRef.set .Dumping
    match ← patchFlareClusterStatus crName ns .Dumping with
    | .error e => IO.eprintln s!"[flare-operator] warning: failed to patch status: {e}"
    | .ok () => pure ()
    IO.eprintln s!"[TRACE] ClusterReplication: None->Dumping | Reason: replication enabled (mode=duplicate)"

  | .Dumping =>
    -- Ensure ConfigMap exists (handle operator restart during Dumping phase)
    -- Check if ConfigMap has replication settings, if not, recreate it
    let cmName := s!"{crName}-config"
    match ← readFlaredConfigMap cmName ns with
    | .error _ =>
      -- ConfigMap doesn't exist or can't be read - recreate it
      IO.eprintln s!"[flare-operator] WARNING: Dumping phase but ConfigMap missing, recreating..."
      match ← updateFlaredReplicationConfig crName ns repl rocksdb with
      | .error e =>
        IO.eprintln s!"[flare-operator] ERROR: failed to recreate replication config: {e}"
        return
      | .ok () =>
        IO.eprintln s!"[DEBUG] handleClusterReplication: ConfigMap recreated in Dumping phase"
        sendSighupToPods crName ns
    | .ok data =>
      -- ConfigMap exists, check if it has replication settings
      if !containsSubstr data "cluster-replication" then
        IO.eprintln s!"[flare-operator] WARNING: ConfigMap exists but missing replication settings, updating..."
        match ← updateFlaredReplicationConfig crName ns repl rocksdb with
        | .error e =>
          IO.eprintln s!"[flare-operator] ERROR: failed to update replication config: {e}"
          return
        | .ok () =>
          IO.eprintln s!"[DEBUG] handleClusterReplication: ConfigMap updated in Dumping phase"
          sendSighupToPods crName ns

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
      match ← updateFlaredReplicationConfig crName ns forwardRepl rocksdb with
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
-- Partition Reduction Detection
-- ===========================================================================

/-- Count the number of active partitions in the cluster state.
    Returns the highest partition index + 1 (since partitions are 0-indexed). -/
private def countActivePartitions (state : FlareClusterState) : Nat :=
  match state.partitionMap.map Prod.fst |>.max? with
  | none => 0
  | some maxIdx => maxIdx + 1

/-- Detect unsafe partition reduction and warn the user.
    Returns true if partition reduction was detected (and blocked). -/
private def detectPartitionReduction (state : FlareClusterState) (crd : FlareClusterView)
    (_crName : String) : IO Bool := do
  let currentPartitions := countActivePartitions state
  let desiredPartitions := crd.spec.partitions

  if desiredPartitions < currentPartitions && currentPartitions > 0 then
    IO.eprintln ""
    IO.eprintln "WARNING: UNSAFE PARTITION REDUCTION DETECTED"
    IO.eprintln "============================================="
    IO.eprintln ""
    IO.eprintln ("CRD specifies " ++ toString desiredPartitions ++ " partitions, but cluster has " ++ toString currentPartitions ++ " partitions")
    IO.eprintln "Reducing partitions directly will cause DATA LOSS!"
    IO.eprintln ""
    IO.eprintln "To safely reduce partitions, use cluster replication:"
    IO.eprintln "1. Create new cluster with fewer partitions"
    IO.eprintln "2. Enable cluster replication on old cluster"
    IO.eprintln "3. Wait for data migration to complete"
    IO.eprintln "4. Switch application to new cluster"
    IO.eprintln "5. Delete old cluster"
    IO.eprintln ""
    IO.eprintln "For detailed instructions, see: docs/PARTITION_REDUCTION.md"
    IO.eprintln ""
    IO.eprintln ("The operator will IGNORE this partition reduction (keeping " ++ toString currentPartitions ++ " partitions)")
    IO.eprintln ""
    pure true
  else
    pure false

-- ===========================================================================
-- Proxy Assignment Helper
-- ===========================================================================

/-- Assign roles to any Proxy nodes.
    This triggers the C++ state machine's role shift: when flared receives a
    topology broadcast showing Proxy → Master/Slave, it calls _shift_node_role(),
    spawns reconstruction thread, and sends "node state ready" upon completion. -/
private def assignProxies (state : FlareClusterState) (crd : FlareClusterView) : FlareClusterState :=
  -- Fold over all nodes, assigning any Proxies
  state.nodeMap.foldl (init := state) fun currentState (nodeKey, node) =>
    if node.role == FlareRole.Proxy then
      let (newState, _) := autoAssign currentState crd nodeKey node
      newState
    else
      currentState

-- ===========================================================================
-- FSM IO Interpreters (Phase 3)
-- ===========================================================================

/-- Execute a K8s API request from the FSM.
    Maps K8sRequest to actual kubectl/K8s.Bridge calls. -/
private def executeK8sRequest (req : K8sReconciler.K8sRequest) (crName ns : String)
    : IO K8sReconciler.K8sResponse := do
  match req with
  | .FetchCRD =>
    match ← getFlareClusterCRD crName ns with
    | .ok crd => pure (.CRDResponse (some crd))
    | .error _ => pure (.CRDResponse none)
  | .ListPods =>
    let pods ← Bridge.listFlaredPods crName ns
    -- Convert pod names to node keys (FQDNs with port) to match nodeMap keys
    let podKeys := pods.map Bridge.PodInfo.toNodeKey
    pure (.PodListResponse podKeys)
  | .PatchService =>
    -- Service patching happens in executeEffects (PatchService effect)
    -- This just signals completion
    pure (.PatchResponse true)
  | .None =>
    pure .NoResponse

/-- Execute a list of side effects from the FSM.
    Maps FlareEffect to actual IO operations. -/
private def executeEffects (effects : List K8sReconciler.FlareEffect)
    (crName ns : String) (_stateRef : IO.Ref FlareClusterState)
    (migrationRef : IO.Ref MigrationPhase) : IO Unit := do
  for eff in effects do
    match eff with
    | .Log msg =>
      IO.eprintln msg

    | .PatchService svcName podName =>
      -- Update K8s Service selector to point to the master pod
      match ← patchClientServiceSelector svcName ns podName with
      | .ok () => pure ()
      | .error e => IO.eprintln s!"[flare-operator] warning: failed to patch service {svcName}: {e}"

    | .BroadcastTopology version nodes =>
      -- Send topology to all flared nodes via TCP
      let nodeList := nodes.map (·.snd)
      broadcastTopologyToAllPods crName ns version nodeList

    | .UpdateConfigMap data =>
      -- Write node map to observability ConfigMap (Main.lean:174-178)
      let cmName := s!"{crName}-node-map"
      match ← updateFlaredConfigMap cmName ns data with
      | .ok () => pure ()
      | .error e => IO.eprintln s!"[flare-operator] warning: failed to update ConfigMap: {e}"

    | .SendSighup _podNames =>
      -- Send SIGHUP to all pods to reload replication config (Main.lean:236)
      sendSighupToPods crName ns

    | .PatchCRDStatus phase =>
      -- Update migration phase in CRD status (Main.lean:238-241)
      migrationRef.set phase
      match ← patchFlareClusterStatus crName ns phase with
      | .ok () => pure ()
      | .error e => IO.eprintln s!"[flare-operator] warning: failed to patch CRD status: {e}"

-- ===========================================================================
-- FSM Driver Loop (Phase 4)
-- ===========================================================================

/-- Per-key merge of the FSM's computed state onto the live ref. The merge
    logic (including the duplicate-master repair for the FSM-vs-TCP assignment
    race) lives in the pure layer so it can be machine-checked; see
    `K8sReconciler.mergeClusterState`. -/
private def mergeClusterState (current ucs : FlareClusterState) : FlareClusterState :=
  K8sReconciler.mergeClusterState current ucs

/-- Commit the FSM's computed cluster state by MERGING it onto the live ref inside
    a single atomic `modifyGet` (see `mergeClusterState`). The merge — not a version
    compare-and-set — is what makes the write safe: a Prepare→Active transition the
    TCP server completed after our snapshot is preserved rather than clobbered, and
    a node registered after our snapshot is carried forward. Always commits.
    `expectedVersion` is retained for call-site compatibility but no longer gates
    the write. -/
private def commitClusterState (stateRef : IO.Ref FlareClusterState)
    (_expectedVersion : Nat) (newState : FlareClusterState) : IO Bool := do
  stateRef.modifyGet fun current =>
    (true, mergeClusterState current newState)

/-- FSM driver loop helper.
    The FSM measure proves termination, but Lean can't see it through IO. -/
private partial def runReconcileFSMLoop
    (s : K8sReconciler.FlareReconcileState)
    (stateRef : IO.Ref FlareClusterState)
    (migrationRef : IO.Ref MigrationPhase)
    (graceCyclesRef : IO.Ref Nat)
    (crName ns : String) : IO Unit := do
  if K8sReconciler.flareReconcileTerminalBool s.reconcileStep then
    -- Terminal state reached
    match s.reconcileStep with
    | .Done =>
      -- Success: update refs for next cycle
      graceCyclesRef.set s.graceCycles
      if let some phase := s.nextMigrationPhase then
        migrationRef.set phase
      pure ()
    | .Error msg =>
      -- Error: log and gracefully exit (operator restarts FSM next tick)
      IO.eprintln s!"[flare-operator] FSM error: {msg}"
      pure ()
    | .EmergencyPaused =>
      -- Circuit breaker tripped - operator stays paused until pod restart
      -- This is intentional: AZ-level failures require manual intervention
      IO.eprintln "[flare-operator] ⚠️  Operator in EMERGENCY PAUSE state"
      IO.eprintln "[flare-operator] ⚠️  Circuit breaker will remain tripped until operator pod is restarted"
      IO.eprintln "[flare-operator] ⚠️  Surviving nodes continue serving traffic"
      pure ()
    | _ =>
      -- Other terminal states (shouldn't happen)
      pure ()
  else
    -- Non-terminal: get current cluster state and transition
    let cs ← stateRef.get
    let csVersion := cs.nodeMapVersion
    let (newState, reqOpt, effects) := K8sReconciler.flareReconcileCore .NoResponse s cs

    -- Execute side effects
    executeEffects effects crName ns stateRef migrationRef

    -- Execute K8s request if present
    match reqOpt with
    | some req =>
      let resp ← executeK8sRequest req crName ns
      let cs2 ← stateRef.get
      let cs2Version := cs2.nodeMapVersion
      let (nextState, nextReqOpt, moreEffects) := K8sReconciler.flareReconcileCore resp newState cs2
      executeEffects moreEffects crName ns stateRef migrationRef

      -- Update cluster state if FSM produced a new one (merge onto the live ref so
      -- a TCP-driven Prepare→Active is preserved; see commitClusterState).
      if let some ucs := nextState.updatedClusterState then
        let _ ← commitClusterState stateRef cs2Version ucs

      -- CRITICAL FIX: Check if FSM issued another request.
      -- If yes, nextState is in a "waiting for response" state and must NOT be called
      -- with .NoResponse. We need to execute the request first.
      match nextReqOpt with
      | some nextReq =>
        -- FSM issued another request - execute it before recursing
        let nextResp ← executeK8sRequest nextReq crName ns
        let cs3 ← stateRef.get
        let cs3Version := cs3.nodeMapVersion
        let (finalState, _, finalEffects) := K8sReconciler.flareReconcileCore nextResp nextState cs3
        executeEffects finalEffects crName ns stateRef migrationRef
        if let some ucs := finalState.updatedClusterState then
          let _ ← commitClusterState stateRef cs3Version ucs
        runReconcileFSMLoop finalState stateRef migrationRef graceCyclesRef crName ns
      | none =>
        -- No new request - safe to recurse (nextState is in an "action" state)
        runReconcileFSMLoop nextState stateRef migrationRef graceCyclesRef crName ns
    | none =>
      -- No request: update cluster state if FSM produced one and continue
      if let some ucs := newState.updatedClusterState then
        let _ ← commitClusterState stateRef csVersion ucs
      runReconcileFSMLoop newState stateRef migrationRef graceCyclesRef crName ns

/-- Run the FSM-driven reconcile loop.
    Repeatedly calls flareReconcileCore, executing requests/effects until Done/Error.
    Implements requirement #5: Error states don't crash the operator; they're logged
    and the FSM restarts from Init on the next tick. -/
private def runReconcileDriver (stateRef : IO.Ref FlareClusterState)
    (migrationRef : IO.Ref MigrationPhase) (graceCyclesRef : IO.Ref Nat)
    (crName ns : String) : IO Unit := do
  let initialGrace ← graceCyclesRef.get
  let initialPhase ← migrationRef.get
  let initialState : K8sReconciler.FlareReconcileState := {
    graceCycles := initialGrace,
    currentMigrationPhase := initialPhase
  }

  runReconcileFSMLoop initialState stateRef migrationRef graceCyclesRef crName ns

-- ===========================================================================
-- FSM-Driven Reconcile (Complete with safety checks and metrics)
-- ===========================================================================

/-- Prepare-stuck watchdog threshold in reconcile cycles (5s each): 720 ≈ 1h. -/
private def prepareStuckThresholdCycles : Nat := 720

/-- FSM-driven reconcile loop with partition reduction safety check and metrics.
    This is the production-ready version that wraps runReconcileDriver.

    LEASE FENCE / dual-leader window: the lease is renewed at the top of each
    outer loop iteration, but a reconcile that outlives the 15s lease (slow
    kubectl, many effects) keeps issuing writes until the NEXT iteration
    notices the loss — during which a new leader may already be active. The
    K8s-side writes are level-triggered and idempotent (the new leader
    re-issues them within one 5s tick), so the damaging stale write is the
    TCP topology broadcast to flared nodes. We therefore re-verify lease
    holdership immediately before broadcasting and skip it if lost. Residual
    window: a broadcast already in flight when the lease flips — bounded by
    one broadcast duration, and corrected by the new leader's next tick. -/
private def reconcileOnceFSM (stateRef : IO.Ref FlareClusterState) (crdRef : IO.Ref FlareClusterView)
    (migrationRef : IO.Ref MigrationPhase) (graceCyclesRef : IO.Ref Nat)
    (prepareCyclesRef : IO.Ref (List (String × Nat)))
    (metrics : OperatorMetrics) (leaseName identity : String)
    (crName ns : String) : IO Unit := do
  -- 1. Fetch CRD (handled by FSM, but we need it early for partition reduction check)
  match ← getFlareClusterCRD crName ns with
  | .error e =>
    IO.eprintln s!"[flare-operator] warning: failed to fetch CRD: {e}"
    return
  | .ok crd =>
    -- 1a. Detect CRD spec changes (for debugging)
    let prevCrd ← crdRef.get
    if prevCrd.spec.partitions != crd.spec.partitions ||
       prevCrd.spec.replicas != crd.spec.replicas then
      IO.eprintln s!"[flare-operator] CRD changed: partitions {prevCrd.spec.partitions}→{crd.spec.partitions}, replicas {prevCrd.spec.replicas}→{crd.spec.replicas}"
    crdRef.set crd

    -- 1b. Detect unsafe partition reduction (safety check BEFORE running FSM)
    let state ← stateRef.get
    let partitionReductionDetected ← detectPartitionReduction state crd crName
    if partitionReductionDetected then
      -- Skip this reconcile cycle to prevent unsafe partition reduction
      return

  -- 2. Run the FSM driver
  let oldVersion := (← stateRef.get).nodeMapVersion
  runReconcileDriver stateRef migrationRef graceCyclesRef crName ns

  -- 3. Post-FSM: Broadcast topology if version changed
  let finalState ← stateRef.get
  let finalVersion := finalState.nodeMapVersion
  if finalVersion != oldVersion then
    -- Lease fence: never broadcast topology from a stale leader (see docstring).
    let stillLeader ← do
      match ← getLease leaseName ns with
      | .ok lease => pure (lease.holderIdentity == identity && !lease.expired)
      | .error e =>
        IO.eprintln s!"[flare-operator] lease fence: getLease failed ({e}); skipping broadcast this tick"
        pure false
    if stillLeader then
      IO.eprintln s!"[flare-operator] topology changed (v{oldVersion} → v{finalVersion}), broadcasting"
      broadcastTopologyToAllPods crName ns finalVersion finalState.getNodes
      recordTopologyBroadcast metrics
      updateNodeMapVersion metrics finalVersion
    else
      IO.eprintln s!"[flare-operator] LEASE FENCE: not the lease holder anymore — suppressing topology broadcast (v{oldVersion} → v{finalVersion})"

  -- 4. Update node counts
  updateNodeCounts metrics finalState

  -- 4b. Prepare-stuck watchdog (alert-only). A node whose reconstruction
  -- stalls stays in Prepare forever: it is deliberately excluded from dead
  -- node detection, so nothing else will ever surface it. Track how many
  -- consecutive reconcile cycles each node has been in Prepare and raise a
  -- log warning + the flare_operator_nodes_prepare_stuck gauge past the
  -- threshold. NO automatic demotion: a 100GB+ dataset legitimately
  -- reconstructs for hours, and demoting it would abort a healthy rebuild.
  let prevCycles ← prepareCyclesRef.get
  let prepareNodes := finalState.nodeMap.filter (fun kv => kv.2.state == FlareState.Prepare)
  let newCycles := prepareNodes.map (fun (key, _) =>
    (key, ((prevCycles.lookup key).getD 0) + 1))
  prepareCyclesRef.set newCycles
  let stuck := newCycles.filter (fun kv => kv.2 > prepareStuckThresholdCycles)
  metrics.prepareStuckCount.set stuck.length.toFloat
  for (key, cycles) in stuck do
    -- Log at the first crossing, then roughly every 10 minutes — not every tick.
    if cycles == prepareStuckThresholdCycles + 1 || cycles % 120 == 0 then
      IO.eprintln s!"[flare-operator] WARNING: node {key} has been in Prepare for {cycles} cycles (~{cycles * 5 / 60} min). Reconstruction may have stalled; check that pod's flared logs. No automatic action is taken."

  -- 5. Handle rocksdb config propagation + cluster replication migration
  let crd ← crdRef.get
  let pods ← Bridge.listFlaredPods crName ns
  handleRocksdbConfig crd crName ns
  handleClusterReplication crd pods migrationRef crName ns

-- ===========================================================================
-- Main Reconcile Loop (Legacy - for comparison/fallback)
-- ===========================================================================

/-- Single iteration of the operator reconcile loop.
    Implements the K8s reconcile pattern:
    fetch CRD → list pods → detect dead → failover → route services → update ConfigMap
    The graceCyclesRef counts down startup grace cycles where dead detection is skipped,
    giving pods time to register via TCP and appear in the K8s ready list. -/
private def reconcileOnce (stateRef : IO.Ref FlareClusterState) (crdRef : IO.Ref FlareClusterView)
    (migrationRef : IO.Ref MigrationPhase) (graceCyclesRef : IO.Ref Nat)
    (metrics : OperatorMetrics) (crName ns : String) : IO Unit := do
  -- 1. Fetch latest CRD spec
  match ← getFlareClusterCRD crName ns with
  | .error e =>
    IO.eprintln s!"[flare-operator] warning: failed to fetch CRD: {e}"
  | .ok crd =>
    crdRef.set crd

    -- 1b. Detect unsafe partition reduction
    let state ← stateRef.get
    let partitionReductionDetected ← detectPartitionReduction state crd crName
    if partitionReductionDetected then
      -- Skip this reconcile cycle to prevent unsafe partition reduction
      return

  -- 2. List live pods (typed PodInfo with readiness)
  let pods ← Bridge.listFlaredPods crName ns

  -- 3. Detect dead nodes (pure) — skipped during startup grace period
  let graceCycles ← graceCyclesRef.get
  let state ← stateRef.get
  let oldVersion := state.nodeMapVersion
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
      -- Record dead nodes detected
      for _ in deadKeys do
        recordDeadNode metrics
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

  -- 5c. Assign roles to any Proxy nodes (triggers role shift in flared)
  let currentState ← stateRef.get
  let crd ← crdRef.get
  let proxyCount := currentState.nodeMap.foldl (init := 0) fun count (_, node) =>
    if node.role == FlareRole.Proxy then count + 1 else count
  let stateAfterAssignment := assignProxies currentState crd
  if stateAfterAssignment.nodeMapVersion != currentState.nodeMapVersion then
    stateRef.set stateAfterAssignment
    IO.eprintln s!"[flare-operator] assigned {proxyCount} proxy node(s) to roles (v{currentState.nodeMapVersion} → v{stateAfterAssignment.nodeMapVersion})"
    -- Log individual node state transitions for debugging
    for (key, newNode) in stateAfterAssignment.nodeMap do
      match currentState.lookupNode key with
      | some oldNode =>
        if oldNode.role != newNode.role || oldNode.partition != newNode.partition then
          let oldRole := match oldNode.role with | .Master => "Master" | .Slave => "Slave" | .Proxy => "Proxy"
          let newRole := match newNode.role with | .Master => "Master" | .Slave => "Slave" | .Proxy => "Proxy"
          let newState' := match newNode.state with | .Active => "Active" | .Prepare => "Prepare" | .Down => "Down" | .Ready => "Ready"
          IO.eprintln s!"[NodeState] {key}: {oldRole} P{oldNode.partition} → {newRole}/{newState'} P{newNode.partition}"
      | none =>
        let newRole := match newNode.role with | .Master => "Master" | .Slave => "Slave" | .Proxy => "Proxy"
        let newState' := match newNode.state with | .Active => "Active" | .Prepare => "Prepare" | .Down => "Down" | .Ready => "Ready"
        IO.eprintln s!"[NodeState] {key}: (new) → {newRole}/{newState'} P{newNode.partition}"
    -- Update node counts after assignment
    updateNodeCounts metrics stateAfterAssignment
  else
    -- No assignment happened - log if there were proxies
    if proxyCount != 0 then
      IO.eprintln s!"[flare-operator] DEBUG: {proxyCount} proxy nodes but no assignments (CRD: {crd.spec.partitions}P × {crd.spec.replicas}R)"

  -- 6. Update ConfigMap for observability
  let currentState ← stateRef.get
  updateObservabilityConfigMap currentState crName ns

  -- 7. Detect and restart lagging/zombie pods (disabled: too aggressive during startup)
  -- detectAndRestartLaggingPods currentState pods ns

  -- 8. Broadcast topology if version changed since start of reconcile cycle
  -- This catches state changes from both failover AND TCP server (node add/state transitions)
  let finalState ← stateRef.get
  let finalVersion := finalState.nodeMapVersion
  if finalVersion != oldVersion then
    IO.eprintln s!"[flare-operator] topology changed during reconcile (v{oldVersion} → v{finalVersion}), broadcasting to all pods"
    broadcastTopologyToAllPods crName ns finalVersion finalState.getNodes
    -- Track topology broadcast
    recordTopologyBroadcast metrics
    -- Update node map version gauge
    updateNodeMapVersion metrics finalVersion

  -- 9. Handle cluster replication migration + rocksdb config propagation
  let crd ← crdRef.get
  handleRocksdbConfig crd crName ns
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

  -- Initialize health status
  let healthStatus ← HealthStatus.new
  healthStatus.setLeader true  -- We just acquired the lease
  IO.eprintln s!"[flare-operator] health status initialized (leader=true)"

  -- Start health check HTTP server in background
  startHealthServerBackground healthStatus
  IO.eprintln s!"[flare-operator] health check server started on port 8080"

  -- Initialize metrics
  let metrics ← initMetrics
  IO.eprintln s!"[flare-operator] metrics initialized"

  -- Start metrics HTTP server in background
  startMetricsServerBackground metrics crName
  IO.eprintln s!"[flare-operator] metrics server started on port 9090"

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
  -- Fetch CRD BEFORE starting TCP server so META returns correct partition-size
  -- from the very first request. Without this, flared nodes connecting early
  -- would get partition-size=1 and operate in single-partition mode permanently.
  let initialCrd ← do
    match ← getFlareClusterCRD crName ns with
    | .ok crd =>
      IO.eprintln s!"[flare-operator] fetched CRD: partitions={crd.spec.partitions}, replicas={crd.spec.replicas}"
      pure crd
    | .error e =>
      IO.eprintln s!"[flare-operator] warning: could not fetch CRD on startup: {e}, retrying..."
      -- Retry up to 10 times with 2s delay — CRD must be available before serving META
      let mut result : FlareClusterView := {
        metadata := { name := some crName, «namespace» := some ns }
        spec := { partitions := 1, replicas := 1 }
      }
      let mut fetched := false
      for _ in List.range 10 do
        IO.sleep 2000
        match ← getFlareClusterCRD crName ns with
        | .ok crd =>
          IO.eprintln s!"[flare-operator] fetched CRD on retry: partitions={crd.spec.partitions}, replicas={crd.spec.replicas}"
          result := crd
          fetched := true
          break
        | .error _ => pure ()
      if !fetched then
        IO.eprintln s!"[flare-operator] CRITICAL: could not fetch CRD after retries, META will return wrong partition-size"
      pure result
  let crdRef ← IO.mkRef initialCrd
  -- Always start from None phase - operator manages migration state internally
  let migrationRef ← IO.mkRef MigrationPhase.None

  -- Startup grace period: skip dead node detection for the first N reconcile cycles
  -- to let all pods register via TCP and appear in the K8s ready list.
  --
  -- Production sizing: 24 cycles × 5s = 120s.  RocksDB-backed nodes with large
  -- datasets (100 GB+) can take 30-60s just to open the database and send the
  -- initial `node add`.  The previous value of 6 cycles (30s) was too aggressive
  -- for production workloads — nodes that hadn't registered yet would be invisible
  -- to the operator (not in nodeMap), and once the grace period expired, the
  -- operator would start assigning roles to the subset that *had* registered,
  -- potentially causing unnecessary partition rebalancing.
  --
  -- Note: this grace period only affects dead-node detection at startup.
  -- Nodes in Prepare state (actively reconstructing) are separately protected
  -- by detectDeadNodes regardless of the grace period.
  let graceCyclesRef ← IO.mkRef (24 : Nat)
  let prepareCyclesRef ← IO.mkRef ([] : List (String × Nat))

  -- Start TCP server in background (using Server.TcpServer)
  let _ ← IO.asTask (prio := .default) do
    try
      startServerFromRefs port stateRef crdRef
    catch e =>
      IO.eprintln s!"[flare-operator] TCP server error: {e}"

  -- Mark TCP server as ready for health checks
  healthStatus.setTcpServerReady true
  IO.eprintln s!"[flare-operator] TCP server marked ready for health checks"

  -- Reconcile loop with lease renewal
  while true do
    -- Renew lease each iteration
    let renewed ← tryAcquireOrRenew leaseName ns identity
    if !renewed then
      IO.eprintln s!"[flare-operator] LOST LEASE -- exiting"
      healthStatus.setLeader false  -- Update health status before exit
      throw (IO.userError "lease lost")

    -- Time the reconcile loop
    let startTime ← IO.monoMsNow
    try
      -- Use FSM-driven reconcile (complete implementation with all 5 requirements)
      reconcileOnceFSM stateRef crdRef migrationRef graceCyclesRef prepareCyclesRef metrics leaseName identity crName ns
    catch e =>
      IO.eprintln s!"[flare-operator] reconcile error: {e}"
    let endTime ← IO.monoMsNow
    let durationMs := endTime - startTime
    let durationSeconds := durationMs.toFloat / 1000.0
    recordReconcileDuration metrics durationSeconds

    -- Log reconcile duration and cluster summary for production debugging.
    -- Only log when duration > 1s (to avoid noise in normal operation) or
    -- every 12th cycle (~60s at 5s interval) as a heartbeat.
    let state ← stateRef.get
    let nodeCount := state.nodeMap.length
    let masterCount := state.nodeMap.filter (fun (_, n) => n.role == FlareRole.Master) |>.length
    let slaveCount := state.nodeMap.filter (fun (_, n) => n.role == FlareRole.Slave) |>.length
    let downCount := state.nodeMap.filter (fun (_, n) => n.state == FlareState.Down) |>.length
    let prepareCount := state.nodeMap.filter (fun (_, n) => n.state == FlareState.Prepare) |>.length
    if durationMs > 1000 then
      IO.eprintln s!"[flare-operator] reconcile slow: {durationMs}ms (nodes={nodeCount} M={masterCount} S={slaveCount} D={downCount} P={prepareCount})"

    IO.sleep (interval * 1000).toUInt32

end FlareOperator

def main (args : List String) : IO Unit :=
  FlareOperator.main args
