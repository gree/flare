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
import FlareOperator.StateMachine.ReplicaRepair
import FlareOperator.StateMachine.SyncEvidence
import FlareOperator.StateMachine.StatsObservation
import FlareOperator.Kubectl
import FlareOperator.Server.TcpServer
import FlareOperator.Server.TopologyBroadcast
import FlareOperator.Metrics.Prometheus
import FlareOperator.Metrics.HttpServer
import FlareOperator.Migration.Controller
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

/-- One numeric value out of a flared `stats` reply (`STAT <key> <value>`). -/
private def statNat (out key : String) : Option Nat :=
  (out.splitOn "\n").findSome? fun line =>
    match (line.trim.splitOn " ").filter (· != "") with
    | ["STAT", k, v] => if k == key then v.trim.toNat? else none
    | _ => none

/-- A flared `stats` reply is complete only if the END terminator arrived;
    a reply cut short (timeout, reset) lacks it and must not be read as "the
    backend has no such field". -/
private def statsReplyComplete (out : String) : Bool :=
  (out.splitOn "\n").any fun l => (l.trim.replace "\r" "") == "END"

private def hasSubstr (h needle : String) : Bool := (h.splitOn needle).length > 1

/-- One string value out of a flared `stats` reply. -/
private def statStr (out key : String) : Option String :=
  (out.splitOn "\n").findSome? fun line =>
    match (line.trim.splitOn " ").filter (· != "") with
    | ["STAT", k, v] => if k == key then some v.trim else none
    | _ => none

/-- Persist the replica-repair ledger when it changed (SC-03 / SAF-05) and
    keep the pending gauge current. Loud on failure: an unpersisted ledger is
    exactly what an operator restart would lose. -/
private def persistLedger (crName ns : String) (before after : ReplicaRepair.Ledger)
    (metrics : OperatorMetrics) (dirtyRef : IO.Ref Bool) : IO Unit := do
  if before != after then
    metrics.replicaRepairsPending.set after.entries.length.toFloat
    match ← Bridge.writeRepairLedger crName ns after with
    | .ok _ => dirtyRef.set false
    | .error e =>
      -- Item 4: the in-memory ledger is already updated, so a later pass
      -- with no further change would never re-save. Mark it DIRTY; the
      -- top of every pass retries the write until it lands.
      dirtyRef.set true
      IO.eprintln s!"[flare-operator] WARNING: could not persist the replica repair ledger ({e}); marked unsaved and will retry every pass — an operator restart before that lands would lose: {after.summary}"

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

private def handleRocksdbConfig (crd : FlareClusterView) (crName ns : String)
    (pendingConfRef : IO.Ref (Option (String × Nat))) : IO Unit := do
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
    -- kubelet propagates the ConfigMap into the pods' mounted files
    -- asynchronously (up to ~60-90s); a SIGHUP sent only now can make
    -- flared re-read the OLD file and silently lose the change (observed
    -- as G12-5's stats staying 0 despite flared's reload() being fixed).
    -- SIGHUP immediately anyway (correct when propagation is fast), then
    -- record the desired content as PENDING: each subsequent reconcile
    -- tick re-checks propagation without blocking and re-signals once the
    -- file has landed everywhere. (A synchronous wait here once stalled
    -- the reconcile loop for minutes — never block this path.)
    sendSighupToPods crName ns
    pendingConfRef.set (some (desired.trim, 0))
    IO.eprintln s!"[TRACE] RocksdbConfig: applied {rocksdb.toExtraConf.length} bytes, SIGHUP sent, verification pending"

/-- Order-independent equality of two master signatures ("<partition>:<server>").
    One master per partition, so the entries are unique and a set-compare (equal
    length + every element present) detects any failover/promotion. -/
private def sameMasters (a b : List String) : Bool :=
  a.length == b.length && a.all (fun x => b.contains x)

/-- Reconcile flared's cluster-replication config toward the DECLARED desired
    state in `spec.clusterReplication` (enabled + mode). Key properties:

    * DECLARATIVE, no auto-advance. The USER controls the duplicate→forward
      transition (and thus cutover timing), which differs per use case — a
      Blue/Green move to a different cluster wants human-controlled cutover
      (verify data landed on the target, then flip mode to forward), while a
      partition shrink can be flipped whenever. This removes the old
      thread-polling detector, which could not distinguish "dump finished" from
      "dump never started" and flipped to forward before any data shipped.

    * CANCEL = `enabled=false` (declarative): strips the config, SIGHUPs, phase
      →None. Before cutover this is a clean rollback (traffic never moved).

    * ABORT-ON-MASTER-CHANGE (safety). A master failover/promotion mid-migration
      would leave the target inconsistent (dump runs on masters; the handover
      loses in-flight/forwarded writes). The operator NEVER blocks source-cluster
      failover — instead it fail-safe ABORTS the migration (strip config, SIGHUP,
      phase→None, bump migration_aborted_total) when the master set changes from
      the snapshot taken at start. Because the spec still says enabled=true, once
      the cluster reconverges the migration auto-restarts with a fresh dump from
      the new master (self-healing); to stop for good, set enabled=false.

    migrationPhase mirrors the applied mode: None / Dumping (duplicate) /
    Forwarding (forward). Every config write uses the propagation-confirmed
    re-signal (pendingConfRef) so a SIGHUP never races the async kubelet mount. -/
private def handleClusterReplication
    (crd : FlareClusterView) (state : FlareClusterState)
    (migrationRef : IO.Ref MigrationPhase)
    (pendingConfRef : IO.Ref (Option (String × Nat)))
    (masterSnapshotRef : IO.Ref (Option (List String)))
    (driftTickRef : IO.Ref Nat)
    (metrics : OperatorMetrics)
    (crName ns : String) : IO Unit := do
  let repl := crd.spec.clusterReplication
  let rocksdb := crd.spec.rocksdb
  driftTickRef.modify (· + 1)
  let driftTick ← driftTickRef.get
  let phase ← migrationRef.get
  -- Current master set (one "<partition>:<server>" per partition master).
  let masterSig : List String := state.getNodes.filterMap fun n =>
    if n.role == FlareRole.Master then some s!"{n.partition}:{n.serverName}" else none

  if !repl.enabled then
    -- Disabled / cancelled: STOP flared, not just our bookkeeping (P1-4).
    -- LEVEL-TRIGGERED, not phase-gated: the FSM also reacts to enabled=false
    -- (computeNextReplicationPhase → PatchCRDStatus effect sets migrationRef
    -- to .None) and runs EARLIER in the same tick, so by the time we get
    -- here the phase guard alone is already .None and a phase-only check
    -- skips the real work forever — flared keeps replicating on the stale
    -- `cluster-replication = true` (caught by the disable E2E; also the
    -- operator-restart case, where the in-memory phase is lost while the
    -- ConfigMap still says true). Decide from the CM content itself.
    let cmStillEnabled ← match ← readFlaredExtraConf crName ns with
      | .ok data => pure (containsSubstr data "cluster-replication = true")
      | .error _ => pure false
    if phase != .None || cmStillEnabled then
      match ← clearFlaredReplicationConfig crName ns rocksdb with
      | .error e =>
        IO.eprintln s!"[flare-operator] ERROR: failed to clear replication config: {e} — retrying next tick"
      | .ok () =>
        sendSighupToPods crName ns
        pendingConfRef.set none
        masterSnapshotRef.set none
        migrationRef.set .None
        match ← patchFlareClusterStatus crName ns .None with
        | .error e => IO.eprintln s!"[flare-operator] warning: failed to reset migrationPhase: {e}"
        | .ok () => pure ()
        IO.eprintln s!"[TRACE] ClusterReplication: {phase.toString}->None | replication disabled (config cleared, SIGHUP sent)"
    else if repl.serverName != "" && driftTick % 12 == 0 then
      -- Steady-state guard (~60s cadence, only for clusters that ever had
      -- replication configured): a flared whose stop-SIGHUP was lost keeps
      -- streaming forever with the CM already saying false. Compare the
      -- APPLIED state from flared's own stats and nudge just the drifted
      -- pods (pre-rc32 flared without the stat is skipped).
      let _ ← resignalReplicationDrift crName ns "cluster-replication = false" false ""
    return

  -- ABORT-ON-MASTER-CHANGE: if we are mid-migration and the master set differs
  -- from the snapshot taken at start, a failover/promotion happened — abort to
  -- avoid an inconsistent target. Source-cluster failover is never blocked.
  match ← masterSnapshotRef.get with
  | some snap =>
    if !sameMasters snap masterSig then
      IO.eprintln s!"[flare-operator] WARNING: master changed during cluster replication (start={snap}, now={masterSig}) — ABORTING migration to avoid an inconsistent target (source failover is NOT blocked; migration auto-restarts once the cluster reconverges, or set enabled=false to stop)"
      match ← clearFlaredReplicationConfig crName ns rocksdb with
      | .error e =>
        IO.eprintln s!"[flare-operator] ERROR: abort could not clear replication config: {e} — retrying next tick"
      | .ok () =>
        sendSighupToPods crName ns
        pendingConfRef.set none
        masterSnapshotRef.set none
        migrationRef.set .None
        metrics.migrationAborted.inc
        match ← patchFlareClusterStatus crName ns .None with
        | .error e => IO.eprintln s!"[flare-operator] warning: failed to reset migrationPhase after abort: {e}"
        | .ok () => pure ()
        IO.eprintln s!"[TRACE] ClusterReplication: {phase.toString}->None | ABORTED (master changed mid-migration)"
      return
  | none => pure ()

  -- Convergence guard ONLY when STARTING a migration (no snapshot yet), so the
  -- captured snapshot is complete. Once migrating (snapshot present), a
  -- missing/changed master is already handled by the abort check above, so we
  -- must NOT block here — otherwise a mode transition (duplicate→forward) or any
  -- tick during a brief master blip would stall in the current phase forever.
  if (← masterSnapshotRef.get).isNone && masterSig.length != crd.spec.partitions then
    IO.eprintln s!"[flare-operator] ClusterReplication: waiting for all {crd.spec.partitions} masters before STARTING migration (have {masterSig.length})"
    return

  -- Enabled + converged: honor the user's declared mode. "forward" only if
  -- explicitly requested; anything else (incl. the default) means "duplicate".
  let desiredMode := if repl.mode == "forward" then "forward" else "duplicate"
  let desiredPhase := if desiredMode == "forward" then MigrationPhase.Forwarding else MigrationPhase.Dumping
  let needle := s!"cluster-replication-mode = {desiredMode}"
  let alreadyDesired ← match ← readFlaredExtraConf crName ns with
    | .ok data => pure (containsSubstr data needle)
    | .error _ => pure false
  if alreadyDesired then
    -- Config already carries the desired mode → no rewrite, no SIGHUP storm
    -- (P1-3). Make the phase reflect it and ensure a master snapshot exists
    -- (e.g. after an operator restart mid-migration).
    if (← masterSnapshotRef.get).isNone then
      masterSnapshotRef.set (some masterSig)
    if phase != desiredPhase then
      migrationRef.set desiredPhase
      match ← patchFlareClusterStatus crName ns desiredPhase with
      | .error e => IO.eprintln s!"[flare-operator] warning: failed to patch status: {e}"
      | .ok () => pure ()
      IO.eprintln s!"[TRACE] ClusterReplication: phase now {desiredPhase.toString} (matches applied mode={desiredMode})"
    -- LEVEL-TRIGGER (~30s cadence): the one-shot SIGHUP after the config
    -- write can land BEFORE the kubelet propagates the ConfigMap mount, and
    -- the in-memory pendingConf re-signal does not survive restarts or its
    -- own 60-tick give-up. Compare flared's APPLIED state (its
    -- cluster_replication stats) against the desired one and nudge exactly
    -- the drifted pods — this is what turned a lost re-signal into a
    -- 107-minute silent stall of a migration's Duplicating phase.
    if driftTick % 6 == 0 then
      let nudged ← resignalReplicationDrift crName ns needle true desiredMode
      if nudged > 0 then
        IO.eprintln s!"[flare-operator] ClusterReplication: re-signalled {nudged} drifted pod(s) (desired mode={desiredMode})"
    return
  -- Desired mode not yet applied: write it, SIGHUP, register the propagation-
  -- confirmed re-signal, and snapshot the master set as the migration baseline.
  match ← updateFlaredReplicationConfig crName ns { repl with mode := desiredMode } rocksdb with
  | .error e =>
    IO.eprintln s!"[flare-operator] ERROR: failed to write replication config (mode={desiredMode}): {e}"
    return
  | .ok () => pure ()
  sendSighupToPods crName ns
  pendingConfRef.set (some (needle, 0))
  masterSnapshotRef.set (some masterSig)
  migrationRef.set desiredPhase
  match ← patchFlareClusterStatus crName ns desiredPhase with
  | .error e => IO.eprintln s!"[flare-operator] warning: failed to patch status: {e}"
  | .ok () => pure ()
  IO.eprintln s!"[TRACE] ClusterReplication: {phase.toString}->{desiredPhase.toString} | applied user-declared mode={desiredMode} (SIGHUP sent, propagation re-signal pending, master snapshot captured)"

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
      -- Legacy (non-FSM) path: no pod list is threaded here, so pass every
      -- known key — the liveness filter is a no-op and behavior is
      -- unchanged. The production FSM path passes the real pod list.
      let (newState, _) := autoAssign currentState crd nodeKey node
        (currentState.nodeMap.map Prod.fst)
      newState
    else
      currentState

-- ===========================================================================
-- FSM IO Interpreters (Phase 3)
-- ===========================================================================

/-- Execute a K8s API request from the FSM.
    Maps K8sRequest to actual kubectl/K8s.Bridge calls. -/
private def executeK8sRequest (req : K8sReconciler.K8sRequest) (crName ns : String)
    (stateRef : IO.Ref FlareClusterState)
    (unreadyCyclesRef : IO.Ref (List (String × Nat)))
    (podKeysRef : IO.Ref (List String))
    (podAddrsRef : IO.Ref (List (String × String)))
    (heldKeys : List String)
    : IO K8sReconciler.K8sResponse := do
  match req with
  | .FetchCRD =>
    match ← getFlareClusterCRD crName ns with
    | .ok crd => pure (.CRDResponse (some crd))
    | .error _ => pure (.CRDResponse none)
  | .ListPods =>
    match ← Bridge.listFlaredPodsE crName ns with
    | .error e =>
      -- Abort the cycle rather than fabricate \"zero pods\": an empty list
      -- here reads as \"every node died\" to dead detection. NoResponse
      -- drives the FSM into its Error terminal; the next tick retries.
      IO.eprintln s!"[flare-operator] ERROR: pod listing failed ({e}) — aborting this reconcile cycle"
      pure .NoResponse
    | .ok pods =>
      -- Convert pod names to node keys (FQDNs with port) to match nodeMap keys
      let podKeys := pods.map Bridge.PodInfo.toNodeKey
      -- Stuck-Down recovery reads this to answer "is there a pod to restart?".
      -- Terminating pods are excluded: they are already on their way out (and
      -- on a lost node they stay Terminating until the node object is
      -- removed, so deleting them again would just repeat forever).
      podKeysRef.set ((pods.filter (fun p => !p.terminating)).map Bridge.PodInfo.toNodeKey)
      -- (key, ip) of pods K8s considers READY, for the operator-side
      -- reachability probe: a node that is Ready but that WE cannot reach is
      -- the network-partition case, invisible to every other signal.
      podAddrsRef.set ((pods.filter (fun p => p.ready && !p.terminating)).map
        (fun p => (Bridge.PodInfo.toNodeKey p, p.ip)))
      -- LIVENESS BEYOND POD EXISTENCE. `podKeys` says the pod OBJECT exists,
      -- which a segfaulted flared still satisfies (the container restarts
      -- under the same pod name and IP) — so dead detection never fired and a
      -- crashed master got no failover (observed live 2026-09-07). The
      -- readiness probe is the process-level truth (it asks flared itself
      -- whether it is Active), and K8s already requires 3 consecutive
      -- failures before flipping a pod NotReady; require a further streak of
      -- operator ticks on top so a slow probe under load is never mistaken
      -- for a dead process. Prepare nodes are legitimately NotReady for the
      -- whole reconstruction — detectDeadNodesPure excludes them by state.
      let unreadyDeadCycles := ((← IO.getEnv "FLARE_UNREADY_DEAD_CYCLES").bind (·.toNat?)).getD 6
      let prevUnready ← unreadyCyclesRef.get
      let notReadyKeys := (pods.filter (fun p => !p.ready && !p.terminating)).map Bridge.PodInfo.toNodeKey
      let newUnready := notReadyKeys.map (fun k => (k, ((prevUnready.lookup k).getD 0) + 1))
      unreadyCyclesRef.set newUnready
      let unhealthyKeys := (newUnready.filter (fun kv => kv.2 ≥ unreadyDeadCycles)).map Prod.fst
      for (k, n) in newUnready do
        if n == unreadyDeadCycles then
          IO.eprintln s!"[flare-operator] CRITICAL: node {k} pod is PRESENT but has been NotReady for {n} ticks -> treating it as dead (flared crashed or wedged); failover/refill will act on it"

      -- Topology for zone-aware placement; [] on unlabeled clusters.
      let nodeZones ← Bridge.listNodeZones
      -- Terminating (deletionTimestamp) pods → graceful drain in the FSM.
      let termKeys := Bridge.terminatingPodKeys pods
      -- Data-bearing probe (curr_items > 0 per pod) for the masterless
      -- refill's empty-master guard. GATED: per-pod execs cost seconds on a
      -- loaded node, and running them EVERY tick stretched the reconcile
      -- past timing-sensitive windows (the drain E2E regressed: the demote
      -- never landed inside its 25s window). Probe only on ticks where the
      -- refill could actually act — a masterless partition exists, or a
      -- mapped node's pod is gone (dead candidate: the failover this tick
      -- may leave the partition masterless and the refill runs in the SAME
      -- tick). Steady healthy ticks pay nothing; [] = "no information", the
      -- guard's old-behavior fallback.
      let cs ← stateRef.get
      let csR := cs.rebuildPartitionMap
      let masterless := csR.partitionMap.any (fun kv => kv.2.master.isNone)
        || (csR.partitionMap.isEmpty && !csR.nodeMap.isEmpty)
      let deadCandidate := csR.nodeMap.any (fun kv => !podKeys.contains kv.1)
      -- A node flagged unhealthy is about to be failed over on THIS tick, and
      -- the refill that reseats its partition runs in the same tick — so the
      -- probe must cover that case too. It did not: `deadCandidate` only
      -- looks for a MISSING pod object, which the D2 trigger (pod present,
      -- NotReady) never satisfies, so the empty-master veto silently
      -- degraded to its no-information fallback exactly when a master had
      -- just died. Found by review, not by a test.
      let dataKeys ← if masterless || deadCandidate || !unhealthyKeys.isEmpty then
          Bridge.dataBearingPodKeys pods ns
        else
          pure []
      pure (.PodListResponse podKeys (Bridge.podZones pods nodeZones) termKeys dataKeys unhealthyKeys heldKeys)
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
private def mergeClusterState (current ucs : FlareClusterState)
    (rb : ReadBalanceSpec) (standbyKeys : List String) : FlareClusterState :=
  K8sReconciler.mergeClusterState current ucs rb.master rb.slave standbyKeys

/-- Commit the FSM's computed cluster state by MERGING it onto the live ref inside
    a single atomic `modifyGet` (see `mergeClusterState`). The merge — not a version
    compare-and-set — is what makes the write safe: a Prepare→Active transition the
    TCP server completed after our snapshot is preserved rather than clobbered, and
    a node registered after our snapshot is carried forward.
    `expectedVersion` is retained for call-site compatibility but no longer gates
    the write.

    Quiescence commit: `mergeClusterState` bumps `nodeMapVersion` unconditionally,
    and the FSM re-commits the SAME snapshot ~7×/tick (`updatedClusterState` is set
    once at AfterDetectDead and carried — never cleared — through every downstream
    step, each hitting a commit site). That made even a fully-converged cluster
    advance the version +7 every tick and rebroadcast the identical node sync to
    every pod forever.

    We CANNOT simply suppress the bump whenever the nodeMap is unchanged: the
    periodic version-advancing rebroadcast is LOAD-BEARING for reconstruction.
    flared only re-processes a node sync whose version is strictly newer (the
    fencing gate), and a Prepare node that has finished reconstructing needs that
    fresh broadcast to be re-evaluated and flipped to Active. During reconstruction
    the operator's nodeMap is unchanged tick-to-tick (the node stays Prepare in the
    operator's view until it flips), so suppressing "unchanged" broadcasts wedges
    the node in Prepare forever (observed live: rc19 left nodes stuck Prepare after
    a roll; reverting restored convergence).

    So: advance the version — the broadcast trigger (the `finalVersion != oldVersion`
    gate) — when the topology actually changed OR the cluster is not yet fully at
    rest (any node not Active: Prepare/Ready/Down still converging). Only when the
    cluster is fully converged (every node Active) AND nothing changed do we pin the
    version and go quiescent. This keeps the reconstruction nudge that rc18 relied
    on while eliminating the steady-state +7/tick churn. Returns whether the version
    advanced. -/
private def commitClusterState (stateRef : IO.Ref FlareClusterState)
    (_expectedVersion : Nat) (newState : FlareClusterState)
    (rb : ReadBalanceSpec := {}) (standbyKeys : List String := []) : IO Bool := do
  stateRef.modifyGet fun current =>
    let merged := mergeClusterState current newState rb standbyKeys
    -- `partitionMap` is a pure function of `nodeMap` (rebuildPartitionMap), so
    -- comparing `nodeMap` detects a real topology change.
    let changed := merged.nodeMap != current.nodeMap
    -- Fully at rest only when every node is Active. Any Prepare/Ready/Down node
    -- means convergence is still in progress and needs the periodic rebroadcast.
    let allActive := merged.getNodes.all (fun n => n.state == FlareState.Active)
    if changed || !allActive then
      (true, merged)
    else
      (false, { merged with nodeMapVersion := current.nodeMapVersion })

/-- Test seam used by the topology-authority E2E suite to stop a reconcile
    at one exact point: after the topology change is committed and the
    version has advanced, and before the pre-send lease check.

    `FLARE_TEST_PRESEND_BARRIER` names a directory inside the container.
    The barrier engages only when `<dir>/arm` exists, so the test chooses
    WHICH pass is stopped; it then announces arrival by writing
    `<dir>/reached` (that file is the test's proof the stop position was
    hit, not merely that time passed), disarms itself, and waits for
    `<dir>/release`. The wait is bounded: if nothing releases it the pass
    continues anyway, so an environment variable left set by accident
    delays one broadcast and cannot wedge an operator.

    Deliberately NOT a second implementation of the send path — the pass
    that resumes here is the same one that goes on to check the lease and
    broadcast. -/
private def preSendBarrier (version : Nat) : IO Unit := do
  match ← IO.getEnv "FLARE_TEST_PRESEND_BARRIER" with
  | none => pure ()
  | some dir =>
    let arm : System.FilePath := dir ++ "/arm"
    if !(← arm.pathExists) then
      pure ()
    else
      let reached : System.FilePath := dir ++ "/reached"
      let release : System.FilePath := dir ++ "/release"
      IO.eprintln s!"[flare-operator] TEST BARRIER: holding before the pre-send lease check (v{version})"
      try IO.FS.writeFile reached s!"{version}\n" catch _ => pure ()
      try IO.FS.removeFile arm catch _ => pure ()
      let mut released := false
      for _ in [0:1200] do        -- 1200 x 100ms = 120s ceiling
        if (← release.pathExists) then
          released := true
          break
        IO.sleep 100
      if released then
        IO.eprintln s!"[flare-operator] TEST BARRIER: released (v{version})"
      else
        IO.eprintln s!"[flare-operator] TEST BARRIER: timed out after 120s; continuing (v{version})"
      try IO.FS.removeFile release catch _ => pure ()
      try IO.FS.removeFile reached catch _ => pure ()

/-- FSM driver loop helper.
    The FSM measure proves termination, but Lean can't see it through IO. -/
private partial def runReconcileFSMLoop
    (s : K8sReconciler.FlareReconcileState)
    (stateRef : IO.Ref FlareClusterState)
    (migrationRef : IO.Ref MigrationPhase)
    (graceCyclesRef : IO.Ref Nat)
    (trippedRef : IO.Ref Bool)
    (drainBlockedRef : IO.Ref Nat)
    (unreadyCyclesRef : IO.Ref (List (String × Nat)))
    (podKeysRef : IO.Ref (List String))
    (podAddrsRef : IO.Ref (List (String × String)))
    (heldKeys : List String)
    (crName ns : String) : IO Unit := do
  if K8sReconciler.flareReconcileTerminalBool s.reconcileStep then
    -- Record whether the breaker HELD during this pass (for hysteresis input
    -- next cycle + the flare_operator_circuit_breaker_tripped gauge). NOT the
    -- terminal step alone: a tripped pass that performed a masterless
    -- RecoveryRefill ends in Done, yet must still count as tripped so the
    -- reset keeps requiring healthy% ≥ resetThresholdPercent.
    trippedRef.set (s.breakerHeld || s.reconcileStep == .EmergencyPaused)
    -- CRITICAL drain-guard signal for the flare_operator_drain_no_successor
    -- gauge (draining masters kept because no promotable successor exists).
    drainBlockedRef.set s.drainBlockedCount
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
      -- Circuit breaker tripped and nothing was refillable this pass. The FSM
      -- is rebuilt from Init next tick, so the breaker re-evaluates every 5s:
      -- masterless-refill recovery runs via RecoveryRefill as returning nodes
      -- register, and the trip auto-resets once healthy% reaches the reset
      -- threshold (autoResetEnabled=false keeps it held until pod restart).
      IO.eprintln "[flare-operator] ⚠️  Operator in EMERGENCY PAUSE state (failover/reassignment paused; masterless-refill recovery active)"
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
      let resp ← executeK8sRequest req crName ns stateRef unreadyCyclesRef podKeysRef podAddrsRef heldKeys
      let cs2 ← stateRef.get
      let cs2Version := cs2.nodeMapVersion
      let (nextState, nextReqOpt, moreEffects) := K8sReconciler.flareReconcileCore resp newState cs2
      executeEffects moreEffects crName ns stateRef migrationRef

      -- Update cluster state if FSM produced a new one (merge onto the live ref so
      -- a TCP-driven Prepare→Active is preserved; see commitClusterState).
      if let some ucs := nextState.updatedClusterState then
        let rb := (nextState.cachedCrd.map (·.spec.readBalance)).getD {}
        let _ ← commitClusterState stateRef cs2Version ucs rb nextState.standbyNodeKeys

      -- CRITICAL FIX: Check if FSM issued another request.
      -- If yes, nextState is in a "waiting for response" state and must NOT be called
      -- with .NoResponse. We need to execute the request first.
      match nextReqOpt with
      | some nextReq =>
        -- FSM issued another request - execute it before recursing
        let nextResp ← executeK8sRequest nextReq crName ns stateRef unreadyCyclesRef podKeysRef podAddrsRef heldKeys
        let cs3 ← stateRef.get
        let cs3Version := cs3.nodeMapVersion
        let (finalState, _, finalEffects) := K8sReconciler.flareReconcileCore nextResp nextState cs3
        executeEffects finalEffects crName ns stateRef migrationRef
        if let some ucs := finalState.updatedClusterState then
          let rb := (finalState.cachedCrd.map (·.spec.readBalance)).getD {}
          let _ ← commitClusterState stateRef cs3Version ucs rb finalState.standbyNodeKeys
        runReconcileFSMLoop finalState stateRef migrationRef graceCyclesRef trippedRef drainBlockedRef unreadyCyclesRef podKeysRef podAddrsRef heldKeys crName ns
      | none =>
        -- No new request - safe to recurse (nextState is in an "action" state)
        runReconcileFSMLoop nextState stateRef migrationRef graceCyclesRef trippedRef drainBlockedRef unreadyCyclesRef podKeysRef podAddrsRef heldKeys crName ns
    | none =>
      -- No request: update cluster state if FSM produced one and continue
      if let some ucs := newState.updatedClusterState then
        let rb := (newState.cachedCrd.map (·.spec.readBalance)).getD {}
        let _ ← commitClusterState stateRef csVersion ucs rb newState.standbyNodeKeys
      runReconcileFSMLoop newState stateRef migrationRef graceCyclesRef trippedRef drainBlockedRef unreadyCyclesRef podKeysRef podAddrsRef heldKeys crName ns

/-- Run the FSM-driven reconcile loop.
    Repeatedly calls flareReconcileCore, executing requests/effects until Done/Error.
    Implements requirement #5: Error states don't crash the operator; they're logged
    and the FSM restarts from Init on the next tick. -/
private def runReconcileDriver (stateRef : IO.Ref FlareClusterState)
    (migrationRef : IO.Ref MigrationPhase) (graceCyclesRef : IO.Ref Nat)
    (trippedRef : IO.Ref Bool)
    (drainBlockedRef : IO.Ref Nat)
    (unreadyCyclesRef : IO.Ref (List (String × Nat)))
    (podKeysRef : IO.Ref (List String))
    (podAddrsRef : IO.Ref (List (String × String)))
    (heldKeys : List String)
    (crName ns : String) : IO Unit := do
  let initialGrace ← graceCyclesRef.get
  let initialPhase ← migrationRef.get
  let initialState : K8sReconciler.FlareReconcileState := {
    graceCycles := initialGrace,
    currentMigrationPhase := initialPhase,
    -- Seed the breaker hysteresis from the persistent ref: FSM state
    -- resets every tick, so "was tripped last cycle" must ride in here.
    wasTripped := (← trippedRef.get)
  }

  runReconcileFSMLoop initialState stateRef migrationRef graceCyclesRef trippedRef drainBlockedRef unreadyCyclesRef podKeysRef podAddrsRef heldKeys crName ns

-- ===========================================================================
-- FSM-Driven Reconcile (Complete with safety checks and metrics)
-- ===========================================================================

/-- Prepare-stuck watchdog threshold in reconcile cycles (5s each): 720 ≈ 1h.
    Deliberately high by default (a 100GB+ dataset legitimately rebuilds for
    hours); override with --prepare-stuck-cycles on small clusters where
    minutes of Prepare already means "parked forever" (observed live: a
    lost activation op). -/
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
    (trippedRef : IO.Ref Bool)
    (prepareCyclesRef : IO.Ref (List (String × Nat)))
    (unreadyCyclesRef : IO.Ref (List (String × Nat)))
    (podKeysRef : IO.Ref (List String))
    (podAddrsRef : IO.Ref (List (String × String)))
    (unreachCyclesRef : IO.Ref (List (String × Nat)))
    (reachSlotRef : IO.Ref Nat)
    (ledgerRef : IO.Ref ReplicaRepair.Ledger)
    (ledgerAvailableRef : IO.Ref Bool)
    (ledgerDirtyRef : IO.Ref Bool)
    (episodesRef : IO.Ref (List SyncEvidence.Episode))
    (pendingBroadcastRef : IO.Ref (Option Nat))
    (downCyclesRef : IO.Ref (List (String × Nat)))
    (emptyMasterStreakRef : IO.Ref (List (String × Nat)))
    (probeSlotRef : IO.Ref Nat)
    (pendingConfRef : IO.Ref (Option (String × Nat)))
    (masterSnapshotRef : IO.Ref (Option (List String)))
    (driftTickRef : IO.Ref Nat)
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
    metrics.partitionsDesired.set crd.spec.partitions.toFloat

    -- 1b. Detect unsafe partition reduction (safety check BEFORE running FSM)
    let state ← stateRef.get
    let partitionReductionDetected ← detectPartitionReduction state crd crName
    if partitionReductionDetected then
      -- Skip this reconcile cycle to prevent unsafe partition reduction
      return

  -- 2. Run the FSM driver
  let oldVersion := (← stateRef.get).nodeMapVersion

  -- 2a'. LEDGER FAULT TOLERANCE (item 4). If the ledger could not be read,
  -- retry now and hold every repair action until it can; if the last save
  -- failed, retry the save even though nothing changed since.
  if !(← ledgerAvailableRef.get) then
    match ← Bridge.readRepairLedger crName ns with
    | .ok (some l) =>
      ledgerRef.set l; ledgerAvailableRef.set true
      IO.eprintln s!"[flare-operator] replica repair ledger RECOVERED from status: {l.summary}"
    | .ok none =>
      ledgerAvailableRef.set true
      IO.eprintln "[flare-operator] replica repair ledger: status has none; starting with baselines"
    | .error e =>
      IO.eprintln s!"[flare-operator] WARNING: replica repair ledger still unavailable ({e}); repairs and drop accounting HELD this pass"
  if (← ledgerDirtyRef.get) && (← ledgerAvailableRef.get) then
    match ← Bridge.writeRepairLedger crName ns (← ledgerRef.get) with
    | .ok _ => ledgerDirtyRef.set false; IO.eprintln "[flare-operator] replica repair ledger persisted on retry"
    | .error e => IO.eprintln s!"[flare-operator] WARNING: replica repair ledger still unsaved ({e}); will retry next pass"

  -- 2a. REPLICA REPAIR, part 1 (SC-03 / SAF-02, SAF-05). Act on the ledger
  -- BEFORE the FSM runs, so a demotion is part of what this pass commits
  -- and sends, and the demoted node is held out of THIS pass's assignment.
  -- The decisions are pure (StateMachine/ReplicaRepair.lean); this block
  -- resolves, gates, applies demotions to stateRef and persists.
  let heldKeys : List String ← do
    let ledgerAvailable ← ledgerAvailableRef.get
    if !ledgerAvailable then
      IO.eprintln "[flare-operator] replica repair: ledger unavailable; holding all repair actions this pass"
      pure []
    else
      let led0 ← ledgerRef.get
      let preState ← stateRef.get
      let (led1, voided) := ReplicaRepair.resolve led0 preState
      for e in voided do
        IO.eprintln s!"[flare-operator] CRITICAL: replica repair VOIDED for {e.dest}: it is now a MASTER, so the {e.drops} write(s) master {e.masterKey} dropped to it are missing on a primary and demotion cannot recover them"
        metrics.replicaRepairVoided.inc
      -- Gate from the LAST committed map (this pass has not run yet) and the
      -- breaker's last verdict. A gated request is HELD, not consumed.
      let crdNow ← crdRef.get
      let masterless := (List.range crdNow.spec.partitions).any fun pIdx =>
        !(preState.nodeMap.any fun kv =>
          kv.2.role == FlareRole.Master && kv.2.state == FlareState.Active
            && kv.2.partition == Int.ofNat pIdx)
      let tripped ← trippedRef.get
      let resyncOnDrop := ((← IO.getEnv "FLARE_RESYNC_ON_DROP").map (· != "0")).getD true
      let gate : Option String :=
        if !resyncOnDrop then some "resync disabled (FLARE_RESYNC_ON_DROP=0)"
        else if tripped then some "circuit breaker held"
        else if masterless then some "a partition has no Active master"
        else none
      let (led2, acts) := ReplicaRepair.plan led1 gate.isNone (gate.getD "")
      let mut led3 := led2
      for (rKey, e) in acts do
        let cs ← stateRef.get
        match cs.lookupNode rKey with
        | some rn =>
          if rn.role == FlareRole.Slave then
            let v := cs.nodeMapVersion + 1
            let demoted : FlareNode :=
              { rn with role := FlareRole.Proxy, state := FlareState.Active, partition := -1 }
            stateRef.set { (cs.addNode rKey demoted) with nodeMapVersion := v }
            led3 := ReplicaRepair.markDemoted led3 e.dest v
            metrics.replicaResyncs.inc
            IO.eprintln s!"[flare-operator] REPLICA REPAIR: demoting {rKey} to a live proxy at v{v} — master {e.masterKey} dropped {e.drops} write(s) to it. Held out of assignment until it reports v{v}; then re-seated as Slave/Prepare so flared reconstructs"
          else
            IO.eprintln s!"[flare-operator] replica repair: {rKey} is no longer a Slave; leaving the request pending"
        | none =>
          IO.eprintln s!"[flare-operator] replica repair: {rKey} is not in the map right now; leaving the request pending"
      for e in led3.entries do
        let prevHold := (led0.entries.find? (·.dest == e.dest)).bind (·.hold)
        if e.hold.isSome && prevHold != e.hold then
          IO.eprintln s!"[flare-operator] replica repair HELD for {e.nodeKey.getD e.dest}: {e.hold.getD ""} — the request is retained and runs when the gate opens"
      ledgerRef.set led3
      persistLedger crName ns led0 led3 metrics ledgerDirtyRef
      pure (ReplicaRepair.heldKeys led3)

  let drainBlockedRef ← IO.mkRef 0
  runReconcileDriver stateRef migrationRef graceCyclesRef trippedRef drainBlockedRef unreadyCyclesRef podKeysRef podAddrsRef heldKeys crName ns
  metrics.circuitBreakerTripped.set (if ← trippedRef.get then 1.0 else 0.0)
  -- CRITICAL drain-guard gauge: >0 pages a human — a draining master has no
  -- promotable successor and its partition dies with the pod (see RUNBOOK
  -- #drain-no-successor). Gauge semantics: reflects the LAST completed pass,
  -- clears once the doomed pod is gone (the key stops being Terminating).
  metrics.drainNoSuccessor.set (← drainBlockedRef.get).toFloat

  -- 3. THE topology send. Single path on purpose (SC-01 / SAF-01).
  --
  -- It reads `stateRef` AFTER commitClusterState, so what goes on the wire
  -- is the COMMITTED, merged map — the one the at-most-one-master property
  -- is proved about (SC-02). The FSM used to emit a BroadcastTopology
  -- effect as well, executed before the commit and without any leadership
  -- check; that path published the FSM's own unmerged snapshot and has
  -- been removed.
  --
  -- What the lease check below does and does not buy:
  --   * It prevents a send that STARTS after a confirmed loss, and it
  --     fails closed — a lease read error also suppresses the send.
  --   * It cannot close the check/send race. The lease can be lost between
  --     the read and the first packet, or while the broadcast is in
  --     flight, and nothing here can retract what is already on the wire.
  --   * The real bound on a stale leader is RECIPIENT-side: flared ignores
  --     a node map whose version is not newer than its own
  --     (cluster::reconstruct_node). That fences only a recipient which has
  --     ALREADY observed the newer generation. A pod that missed the new
  --     leader's broadcast — restarted, unreachable at the time, or simply
  --     never sent to — has nothing to compare against and will accept the
  --     old leader's map. Per-node applied-generation tracking is SAF-09.
  -- Both halves are exercised by the topology-authority E2E suite.
  let finalState ← stateRef.get
  let finalVersion := finalState.nodeMapVersion
  -- RETRY A SUPPRESSED SEND. Suppression used to be terminal: the committed
  -- version had already advanced, so the next pass found nothing to send and
  -- the map never reached the nodes until some unrelated change moved the
  -- version again. Carry a flag instead, and let a later pass that does hold
  -- the lease publish the CURRENT committed map, which subsumes whatever was
  -- suppressed.
  --
  -- Scope, because it is easy to over-read: this covers suppression that the
  -- process SURVIVES — a lease read failure, a momentarily foreign holder.
  -- It cannot cover a real takeover, because losing the lease ends the
  -- process ("LOST LEASE -- exiting"); there the next leader republishes
  -- from its own committed state on startup, and whether that reaches a node
  -- still depends on its version being newer (SAF-09).
  -- `some v` = a send of committed version v was suppressed and nothing
  -- has published since. Kept as the EARLIEST suppressed version so the
  -- log can name the pass that was withheld, not just the latest.
  let pendingBefore ← pendingBroadcastRef.get
  -- A node held by the replica-repair ledger has not yet reported the map
  -- that demoted it; re-send the current map every pass until it does.
  -- flared accepts an equal version (only an OLDER one is ignored), so a
  -- node that missed the push catches up on the next one.
  if !heldKeys.isEmpty && finalVersion == oldVersion && pendingBefore.isNone then
    IO.eprintln s!"[flare-operator] re-sending v{finalVersion}: replica repair holds {heldKeys.length} node(s) that have not confirmed the map yet"
  -- KEEP BROADCASTING UNTIL A COMMITTED ACTIVE STATE IS CONFIRMED. A node's
  -- activation reaches the operator over TCP (activate_node) and updates the
  -- committed map directly — out of band from this loop. If that lands while
  -- the map is otherwise at rest, commitClusterState sees "every node Active"
  -- and pins the version, so the active map is NEVER broadcast back; flared
  -- keeps its local state at prepare, waits for the map to echo its
  -- activation, retries activate_node (which the operator now rejects,
  -- state already Active → "not allowed"), and after ~30 failures
  -- deactivates itself to Down. Result on a busy cluster: a reconstructed
  -- replica wedged Down, its partition down to one copy. A pod is only
  -- Ready once flared's OWN map says it is active (the sync-gated probe), so
  -- an Active-in-the-map node whose pod is NOT Ready has not applied the
  -- map. Re-broadcast the current map (flared reprocesses an equal version)
  -- until it has. Bounded: the node either applies it and goes Ready, or is
  -- marked Down by dead detection — both clear the condition.
  let readyKeys := (← podAddrsRef.get).map (·.1)
  let unconfirmedActive := finalState.nodeMap.filter (fun kv =>
    (kv.2.role == FlareRole.Master || kv.2.role == FlareRole.Slave)
      && kv.2.state == FlareState.Active && !readyKeys.contains kv.1)
  if !unconfirmedActive.isEmpty && finalVersion == oldVersion && pendingBefore.isNone && heldKeys.isEmpty then
    IO.eprintln s!"[flare-operator] re-sending v{finalVersion}: {unconfirmedActive.length} node(s) are Active in the map but their pods are not Ready yet (activation not applied locally)"
  if finalVersion != oldVersion || pendingBefore.isSome || !heldKeys.isEmpty || !unconfirmedActive.isEmpty then
    -- TEST SEAM (SAF-01 / CHECK-01). Unset in production, this is one
    -- getEnv and nothing else.
    --
    -- The acceptance scenario for SC-01 is "an old reconcile resumes after
    -- a lease takeover and must not send". Stopping the process at an
    -- arbitrary moment cannot produce it: the send is gated on the version
    -- having advanced, so a pass frozen during the tick sleep resumes into
    -- the loop's own lease renewal and exits before this branch, and a pass
    -- frozen after the check below is the in-flight race this change
    -- documents as NOT closed. The only position that exercises the fence
    -- is here — committed, version advanced, check not yet made — so the
    -- test needs to name it rather than guess it.
    --
    -- One-shot and bounded by construction: it engages only while an `arm`
    -- file exists, disarms itself immediately, and gives up waiting after
    -- the timeout so a stale environment variable can never wedge a real
    -- operator.
    preSendBarrier finalVersion
    let stillLeader ← do
      match ← getLease leaseName ns with
      | .ok lease => pure (lease.holderIdentity == identity && !lease.expired)
      | .error e =>
        IO.eprintln s!"[flare-operator] lease fence: getLease failed ({e}); skipping broadcast this tick"
        pure false
    if stillLeader then
      -- Logged whenever a suppressed send is outstanding, whether or not
      -- the version also moved: the published map subsumes the withheld
      -- one either way, and the line names the withheld version so a test
      -- can tie this send to that suppression. It does NOT claim the send
      -- would not have happened without the flag — when the version moved
      -- as well, it would have.
      if let some suppressedV := pendingBefore then
        IO.eprintln s!"[flare-operator] retrying a suppressed topology send (suppressed v{suppressedV}; publishing v{finalVersion})"
      IO.eprintln s!"[flare-operator] topology changed (v{oldVersion} → v{finalVersion}), broadcasting"
      broadcastTopologyToAllPods crName ns finalVersion finalState.getNodes
      recordTopologyBroadcast metrics
      updateNodeMapVersion metrics finalVersion
      -- Re-read the lease AFTER the send. This cannot prevent the race
      -- above, but it turns it from invisible into an incident record: if
      -- we lost leadership during the broadcast, someone reading these
      -- logs needs to know a stale map may have gone out.
      match ← getLease leaseName ns with
      | .ok l =>
        if l.holderIdentity != identity then
          IO.eprintln s!"[flare-operator] CRITICAL: lease holder changed to '{l.holderIdentity}' DURING a topology broadcast (v{finalVersion}); a map may have been published without authority. Recipients that already saw a newer version rejected it; others did not."
      | .error e =>
        IO.eprintln s!"[flare-operator] warning: could not confirm lease ownership after broadcasting v{finalVersion}: {e}"
      pendingBroadcastRef.set none
    else
      IO.eprintln s!"[flare-operator] LEASE FENCE: not the lease holder anymore — suppressing topology broadcast (v{oldVersion} → v{finalVersion}); held for retry once authority returns"
      pendingBroadcastRef.modify fun p => match p with | some v => some v | none => some finalVersion

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
  -- Env override for small clusters, where minutes of Prepare already
  -- means "parked forever" (inject via the chart's `env:` values).
  let threshold := ((← IO.getEnv "FLARE_PREPARE_STUCK_CYCLES").bind (·.toNat?)).getD
    prepareStuckThresholdCycles
  let stuck := newCycles.filter (fun kv => kv.2 > threshold)
  metrics.prepareStuckCount.set stuck.length.toFloat
  for (key, cycles) in stuck do
    -- Log at the first crossing, then roughly every 10 minutes — not every tick.
    if cycles == threshold + 1 || cycles % 120 == 0 then
      IO.eprintln s!"[flare-operator] WARNING: node {key} has been in Prepare for {cycles} cycles (~{cycles * 5 / 60} min). Reconstruction may have stalled; check that pod's flared logs. No automatic action is taken."

  -- PREPARE ACTIVATION EVIDENCE (SC-04 / SAF-03). flared reports
  -- "reconstruction complete" (Prepare→Active) as a ONE-SHOT TCP event; if
  -- the operator misses it (mid-roll leader swap, a hung loop, a dropped
  -- connection) the node sits Prepare forever: the sync-gated readiness
  -- probe reads the operator's own broadcast back — circular — so the pod
  -- stays NotReady and StatefulSet rolls block behind it (observed live: a
  -- slave with the FULL dataset stuck Prepare for 7h27m). Repair by
  -- re-deriving the transition — but only from evidence bound to THIS
  -- Prepare episode (StateMachine/SyncEvidence.lean): the node's OWN node
  -- map says it is active, a reconstruction completed in its process, its
  -- lineage matches the master's, the master (key and lineage) did not
  -- change while we watched, and its cursor is not ahead of the master's
  -- head. LSN proximity used to be the whole test; it is now only reported.
  -- flared's re-announce ("map says prepare but I am active") is the first
  -- line for a lost event; this is the second. Lag-gated by cycles so a
  -- node still reconstructing is never even examined.
  let repairAfter := ((← IO.getEnv "FLARE_PREPARE_REPAIR_CYCLES").bind (·.toNat?)).getD 36
  let masterOfPartition := fun (part : Int) =>
    finalState.nodeMap.find? fun kv =>
      kv.2.role == FlareRole.Master && kv.2.state == FlareState.Active && kv.2.partition == part
  let current : List (String × String) := finalState.nodeMap.filterMap fun (key, node) =>
    if node.role == FlareRole.Slave && node.state == FlareState.Prepare then
      (masterOfPartition node.partition).map fun (mKey, _) => (key, mKey)
    else none
  let mut episodes := SyncEvidence.reconcileEpisodes (← episodesRef.get) current
  for (key, cycles) in newCycles do
    if cycles >= repairAfter && cycles % 12 == 0 then
      match episodes.find? (·.nodeKey == key), finalState.lookupNode key with
      | some ep, some node =>
        match masterOfPartition node.partition with
        | some (mKey, masterNode) =>
          let slavePod := extractPodName node.serverName
          let sOut ← Bridge.queryPodStats slavePod ns "stats"
          let mOut ← Bridge.queryPodStats (extractPodName masterNode.serverName) ns "stats"
          let reading : SyncEvidence.Reading := match sOut, mOut with
            | .ok so, .ok mo =>
              { bootId := statNat so "reconstruction_boot_id",
                currentId := statNat so "reconstruction_current_id",
                currentState := statStr so "reconstruction_current_state",
                lastSuccessId := statNat so "reconstruction_last_success_id",
                lastSuccessSource := statStr so "reconstruction_last_success_source",
                slaveMasterId := statStr so "rocksdb_master_id",
                slaveLsn := statNat so "rocksdb_repl_last_lsn",
                masterId := statStr mo "rocksdb_master_id",
                masterSeq := statNat mo "rocksdb_latest_sequence_number",
                -- Backend from the MASTER's reply, and only if that reply was
                -- complete: "no rocksdb_ key in a truncated reply" is not
                -- "this backend has no lineage".
                masterIsRocksdb := if statsReplyComplete mo then some (hasSubstr mo "rocksdb_") else none }
            | _, _ => { }
          let (ep', verdict) := SyncEvidence.judge ep mKey reading
          episodes := episodes.map fun e => if e.nodeKey == key then ep' else e
          match verdict with
          | .activate why =>
            let crdNow ← crdRef.get
            let ev := Flare.FlareEvent.NodeState node.serverName node.serverPort FlareState.Active
            let resp ← stateRef.modifyGet fun cs =>
              let (ns', r) := Reconciler.reconcileStep cs crdNow ev
              (r, ns')
            match resp with
            | .OK =>
              IO.eprintln s!"[flare-operator] PREPARE-REPAIR: {key} stuck Prepare {cycles} cycles; {why} -> re-derived Prepare→Active under master {mKey}"
              episodes := episodes.filter (·.nodeKey != key)
            | _ =>
              IO.eprintln s!"[flare-operator] prepare-repair: {key}: evidence sufficient ({why}) but reconcileStep rejected the re-derived activation; leaving Prepare"
          | .wait reason =>
            IO.eprintln s!"[flare-operator] prepare-repair: {key} stuck Prepare {cycles} cycles, NOT activating: {reason}"
          | .sourceChanged reason =>
            IO.eprintln s!"[flare-operator] prepare-repair: {key}: {reason}; episode restarted, a NEW completion is required before activation"
            episodes := episodes.map fun e => if e.nodeKey == key then e.restart mKey else e
        | none => pure ()
      | _, _ => pure ()
  episodesRef.set episodes

  -- Shared safety gates for the two paths below that DELETE pods, plus the
  -- per-partition masterless gauge. Counting the partitions themselves is
  -- the honest version of "is a partition unserved": the cluster-wide
  -- desired-minus-active-masters arithmetic behind FlareMasterMissing can be
  -- offset by a stale master parked at an out-of-range partition index.
  let crdForGates ← crdRef.get
  let masterlessIdxs := (List.range crdForGates.spec.partitions).filter (fun pIdx =>
    !(finalState.nodeMap.any (fun kv =>
        kv.2.role == FlareRole.Master && kv.2.state == FlareState.Active
          && kv.2.partition == Int.ofNat pIdx)))
  metrics.masterlessPartitions.set masterlessIdxs.length.toFloat
  let allPartitionsMastered := masterlessIdxs.isEmpty
  let breakerTripped ← trippedRef.get
  -- Deleting a pod on a tmpfs cluster erases that node's copy, so NEITHER
  -- self-heal may act while a partition is already unserved or while the
  -- blast-radius breaker says the cluster is in a mass-failure regime.
  let podDeletionAllowed := allPartitionsMastered && !breakerTripped

  -- 4d. EMPTY-MASTER SELF-HEAL. rc55 prevents MINTING an empty master, but
  -- one already seated is a stable fixed point: nothing re-evaluates a
  -- sitting master's data (observed live: a rolled-empty ex-master served 0
  -- keys over a slave holding 15.8M — writes proxied into it, reads missed).
  -- Detect it from ground truth (curr_items probes, one burst per ~5 min)
  -- and heal through the PROVEN drain path: gracefully delete the empty
  -- master's pod — the drain guard demotes it and promotes the data-bearing
  -- Active slave, and the pod returns as a slave and reseeds. Guards:
  -- requires an Active data-bearing slave in the SAME partition, and the
  -- condition must persist 3 consecutive probes (~15 min) before acting.
  -- 2b. REPLICA REPAIR, part 2: advance the ledger from what the nodes
  -- themselves report — their applied node_map_version (confirms the
  -- demotion) and their reconstruction_completed counter (confirms the
  -- rebuild). Runs every pass while anything is pending; one `stats` exec
  -- per pending replica, nothing when the ledger is empty.
  do
    let ledgerAvailable ← ledgerAvailableRef.get
    if ledgerAvailable then
      let led0 ← ledgerRef.get
      if !led0.entries.isEmpty then
        let mut obs : List (String × ReplicaRepair.Observation) := []
        for e in led0.entries do
          match e.nodeKey with
          | none => pure ()
          | some k =>
            let mapped := (finalState.lookupNode k).map fun n => (n.role, n.state)
            -- The success must have copied from the node's CURRENT master.
            let currentMaster := (finalState.lookupNode k).bind fun n =>
              (finalState.nodeMap.find? fun kv =>
                kv.2.role == FlareRole.Master && kv.2.state == FlareState.Active && kv.2.partition == n.partition).map (·.1)
            let o : ReplicaRepair.Observation ← do
              match ← Bridge.queryPodStats (extractPodName k) ns "stats" with
              | .ok out => pure { reportedVersion := statNat out "node_map_version",
                                  bootId := statNat out "reconstruction_boot_id",
                                  currentId := statNat out "reconstruction_current_id",
                                  currentState := statStr out "reconstruction_current_state",
                                  lastSuccessId := statNat out "reconstruction_last_success_id",
                                  lastSuccessSource := statStr out "reconstruction_last_success_source",
                                  currentMaster := currentMaster, mapped := mapped }
              | .error _ => pure { mapped := mapped, currentMaster := currentMaster }
            obs := obs ++ [(e.dest, o)]
        let (led1, steps) := ReplicaRepair.advance led0 obs
        for (e, st) in steps do
          let who := e.nodeKey.getD e.dest
          match st with
          | .released =>
            metrics.replicaRepairStarted.inc
            IO.eprintln s!"[flare-operator] REPLICA REPAIR: {who} confirmed the demotion ({e.phase}); released to assignment — the next pass re-seats it as Slave/Prepare and flared reconstructs"
          | .completed =>
            metrics.replicaRepairCompleted.inc
            IO.eprintln s!"[flare-operator] REPLICA REPAIR COMPLETE: {who} is Slave/Active; a reconstruction newer than the one current at reseat (#{e.currentIdAtReseat.getD 0}, boot {e.bootIdAtReseat.getD 0}) SUCCEEDED from its current master; {e.drops} dropped write(s) recovered"
          | .completedRequeued =>
            -- Item 3: drops kept arriving after the reconstruction began; the
            -- copy may not hold them. The first repair is complete, and the
            -- increment is already back in the ledger as a fresh request.
            metrics.replicaRepairCompleted.inc
            metrics.replicaRepairRequested.inc
            IO.eprintln s!"[flare-operator] REPLICA REPAIR COMPLETE (with late drops): {who} reconstructed, but {e.drops - e.dropsAtReseat} write(s) were dropped to it after the reconstruction began and may not be in the copy — REQUEUED as a new request"
          | .voided =>
            metrics.replicaRepairVoided.inc
            IO.eprintln s!"[flare-operator] CRITICAL: replica repair VOIDED for {who}: it became a MASTER while under repair; the {e.drops} write(s) it missed are now missing on a primary"
          | .none => pure ()
        ledgerRef.set led1
        persistLedger crName ns led0 led1 metrics ledgerDirtyRef

  -- Stats probe cadence. 5 minutes in production; the harness shortens it
  -- (FLARE_STATS_PROBE_INTERVAL_MS) so a repair can be watched in minutes.
  let probeIntervalMs := max 1000 (((← IO.getEnv "FLARE_STATS_PROBE_INTERVAL_MS").bind (·.toNat?)).getD 300000)
  let probeSlot := (← IO.monoMsNow) / probeIntervalMs
  if probeSlot != (← probeSlotRef.get) then
    probeSlotRef.set probeSlot
    let streaks ← emptyMasterStreakRef.get
    let mut newStreaks : List (String × Nat) := []
    -- Largest divergence seen in THIS round; published once below so the
    -- gauge reflects the latest probe rather than an all-time high-water
    -- mark that could never recover.
    let mut maxKeyGap : Float := 0.0
    for (mKey, mNode) in finalState.nodeMap do
      if mNode.role == FlareRole.Master && mNode.state == FlareState.Active then
        -- an Active slave of the same partition to compare against / promote
        match finalState.nodeMap.find? (fun kv =>
            kv.2.role == FlareRole.Slave && kv.2.state == FlareState.Active
              && kv.2.partition == mNode.partition) with
        | some (sKey, sNode) =>
          let mOut ← Bridge.queryPodStats (extractPodName mNode.serverName) ns "stats"
          let sOut ← Bridge.queryPodStats (extractPodName sNode.serverName) ns "stats"
          match mOut, sOut with
          | .ok mo, .ok so =>
            let items := fun (out : String) =>
              ((out.splitOn "
" |>.filterMap fun line =>
                match (line.trim.splitOn " ").filter (· != "") with
                | ["STAT", "curr_items", v] => v.trim.toNat?
                | _ => none).head?).getD 0
            -- Both counts are already in hand: record the divergence while
            -- we are here (no extra probe). Coarse by construction — equal
            -- counts do not prove equal content — but a persistent gap is
            -- the only cheap signal that live proxy replication has been
            -- losing writes (nothing else compares the copies).
            let mi := items mo
            let si := items so
            if mi > 0 then
              let gap := (if mi > si then mi - si else si - mi).toFloat / mi.toFloat
              if gap > maxKeyGap then
                maxKeyGap := gap
              if gap > 0.001 then
                IO.eprintln s!"[flare-operator] replica divergence: master {mKey} has {mi} keys, slave has {si} ({(gap * 100.0).toString.take 5}% apart) — live replication has no per-write ack, so a gap here means writes were dropped or expired only on one side"
            -- DROPPED REPLICA WRITES → the repair ledger (SC-03). The master
            -- reports, per destination, how many replica writes it gave up
            -- forwarding; live replication has no per-write acknowledgement,
            -- so this is the only signal that a replica is quietly behind.
            -- Here we only OBSERVE: deltas become repair requests. What
            -- happens to a request — hold, demote, confirm, re-seat,
            -- complete — is decided in StateMachine/ReplicaRepair.lean and
            -- applied in parts 1 and 2 of this pass. A counter that went
            -- DOWN is a restarted master whose count is entirely new drops.
            let drops := (mo.splitOn "\n").filterMap fun line =>
              match (line.trim.splitOn " ").filter (· != "") with
              | ["STAT", k, v] =>
                if k.startsWith "proxy_write_dropped[" && k.endsWith "]" then
                  let dest := (k.drop "proxy_write_dropped[".length).dropRight 1
                  match v.trim.toNat? with
                  | some n => some (dest, n)
                  | none => none
                else none
              | _ => none
            -- Item 4: no accounting on a ledger we could not read.
            if (← ledgerAvailableRef.get) then
              let led0 ← ledgerRef.get
              let (led1, newDrops) := ReplicaRepair.observe led0 mKey drops
              let mut led2 := led1
              for (dest, d) in newDrops do
                IO.eprintln s!"[flare-operator] REPLICA REPAIR requested: master {mKey} dropped {d} more write(s) to {dest} — that replica is behind and nothing else repairs it"
                metrics.replicaRepairRequested.inc
                led2 := ReplicaRepair.request led2 mKey dest d
              if !led0.initialized then
                IO.eprintln s!"[flare-operator] replica repair ledger initialized from {mKey}: {drops.length} destination counter(s) recorded as baseline, none attributed"
              ledgerRef.set led2
              persistLedger crName ns led0 led2 metrics ledgerDirtyRef
            -- EMPTY-MASTER decision, typed (SC-05 / SAF-04). `items` returns
            -- 0 for a missing curr_items line as readily as for a real zero;
            -- a truncated stats reply must NOT read as "empty, delete it".
            -- StatsObservation makes an unreadable count `unknown`, and the
            -- verdict deletes only on a KNOWN 0 master with a KNOWN nonzero
            -- successor.
            let mObs := StatsObservation.parseCurrItems mo
            let sObs := StatsObservation.parseCurrItems so
            match StatsObservation.emptyMasterVerdict mObs sObs with
            | .act =>
              let streak := ((streaks.lookup mKey).getD 0) + 1
              newStreaks := newStreaks ++ [(mKey, streak)]
              IO.eprintln s!"[flare-operator] WARNING: master {mKey} is EMPTY (0 keys) while an Active slave holds {sObs} keys (streak {streak}/3)"
              if streak ≥ 3 && podDeletionAllowed then
                -- SAF-06 REVALIDATION (item 5). The streak decision rests on a
                -- snapshot; between it and the delete a resync may have
                -- demoted the successor, the pod may have been REPLACED
                -- under the same name, or leadership lost. Re-check
                -- everything in an order that closes those windows:
                --   1. the target pod's UID before the stats read,
                --   2. FRESH stats for master and successor,
                --   3. the UID again (same pod observed?),
                --   4. the live map AFTER the stats (any change during the
                --      reads is now visible),
                --   5. the leader lease,
                -- and delete through a UID-checked path so a pod replaced
                -- after step 3 is not deleted either. One pure gate decides.
                let mPod := extractPodName mNode.serverName
                let uidBefore ← Bridge.podUid mPod ns
                let freshM ← Bridge.queryPodStats mPod ns "stats"
                let freshS ← Bridge.queryPodStats (extractPodName sNode.serverName) ns "stats"
                let uidAfter ← Bridge.podUid mPod ns
                let liveState ← stateRef.get
                let mNow := match freshM with | .ok o => StatsObservation.parseCurrItems o | .error _ => .unknown
                let sNow := match freshS with | .ok o => StatsObservation.parseCurrItems o | .error _ => .unknown
                let dataBearing := match sNow with | .known n => if n > 0 then [sKey] else [] | .unknown => []
                let verdictNow := StatsObservation.emptyMasterVerdict mNow sNow
                let successorOk := StatsObservation.successorStillValid liveState mKey sKey dataBearing
                let uidStable := match uidBefore, uidAfter with | some a, some b => a == b | _, _ => false
                let holdsLease ← do
                  match ← getLease leaseName ns with
                  | .ok lease => pure (lease.holderIdentity == identity && !lease.expired)
                  | .error _ => pure false
                match StatsObservation.deleteGate verdictNow successorOk uidStable holdsLease, uidBefore with
                | .ok (), some uid =>
                  IO.eprintln s!"[flare-operator] EMPTY-MASTER SELF-HEAL: revalidated (master still empty, successor {sKey} still an Active data-bearing slave, pod UID {uid} stable, lease held); gracefully deleting {mPod} — the drain path hands mastership to the slave and the pod reseeds as a slave"
                  match ← Bridge.deletePodGracefulIfUid mPod ns uid with
                  | .ok () => newStreaks := newStreaks.filter (·.1 != mKey)
                  | .error e => IO.eprintln s!"[flare-operator] empty-master self-heal delete refused or failed: {e}"
                | .ok (), none =>
                  IO.eprintln s!"[flare-operator] EMPTY-MASTER SELF-HEAL ABORTED: no readable UID for {mPod}; not deleting by name alone"
                  newStreaks := newStreaks.filter (·.1 != mKey)
                | .error why, _ =>
                  IO.eprintln s!"[flare-operator] EMPTY-MASTER SELF-HEAL ABORTED at revalidation: {why} (master now {mNow}, successor {sKey} now {sNow}) — NOT deleting {mPod}"
                  newStreaks := newStreaks.filter (·.1 != mKey)
            | .skip reason =>
              -- Not empty, or the observation was not clear enough to act on.
              -- Clear any streak: an unknown or nonzero reading breaks it.
              if StatsObservation.parseCurrItems mo == StatsObservation.Items.unknown then
                IO.eprintln s!"[flare-operator] empty-master check: master {mKey} item count unreadable this pass — {reason}; streak reset"
              newStreaks := newStreaks.filter (·.1 != mKey)
          | _, _ => pure ()
        | none => pure ()
    emptyMasterStreakRef.set newStreaks
    metrics.replicaKeyDelta.set maxKeyGap

  -- 4e. LIVENESS metrics + STUCK-DOWN recovery. A node leaves Down only by
  -- RE-REGISTERING, which needs a fresh flared process: while the committed
  -- map says Down the readiness probe keeps failing (it asks flared for its
  -- own Active state), so the loop is closed by a restart and nothing else.
  -- The tcpSocket liveness probe covers a dead or hung port, but a flared
  -- that still answers while marked Down would sit there forever — including
  -- one the new unhealthy detection just demoted. So restart it here, under
  -- hard gates: a demoted (Proxy) Down node, pod present, for minutes, with
  -- EVERY partition already holding an Active master (never delete the last
  -- data-bearing copy — on tmpfs that IS the data), breaker not tripped, and
  -- at most one pod per tick.
  let podKeysNow ← podKeysRef.get
  let unreadyNow ← unreadyCyclesRef.get
  let unreadyDeadCycles := ((← IO.getEnv "FLARE_UNREADY_DEAD_CYCLES").bind (·.toNat?)).getD 6
  metrics.unhealthyNodes.set (unreadyNow.filter (fun kv => kv.2 ≥ unreadyDeadCycles)).length.toFloat
  let downPresent := finalState.nodeMap.filter (fun kv =>
    kv.2.state == FlareState.Down && podKeysNow.contains kv.1)
  metrics.stuckDownNodes.set downPresent.length.toFloat
  let prevDown ← downCyclesRef.get
  let newDown := downPresent.map (fun kv => (kv.1, ((prevDown.lookup kv.1).getD 0) + 1))
  downCyclesRef.set newDown
  let downRestartCycles := ((← IO.getEnv "FLARE_DOWN_RESTART_CYCLES").bind (·.toNat?)).getD 60
  if downRestartCycles > 0 then
    if podDeletionAllowed then
      match newDown.find? (fun kv => kv.2 ≥ downRestartCycles) with
      | some (key, cycles) =>
        match finalState.lookupNode key with
        | some node =>
          if node.role == FlareRole.Proxy then
            let podName := extractPodName node.serverName
            IO.eprintln s!"[flare-operator] STUCK-DOWN RECOVERY: {key} has been Down with its pod present for {cycles} ticks (~{cycles * 5 / 60} min); every partition has an Active master, so restarting {podName} to force a clean re-registration (it will rejoin via Prepare and catch up)"
            match ← Bridge.deletePodGraceful podName ns with
            | .ok () => downCyclesRef.set (newDown.filter (fun kv => kv.1 != key))
            | .error e => IO.eprintln s!"[flare-operator] stuck-down recovery: failed to delete {podName}: {e}"
        | none => pure ()
      | none => pure ()

  -- 4f. OPERATOR-SIDE REACHABILITY. Every other liveness signal is blind to
  -- the operator→pod path: the readiness probe runs inside the pod (kubelet
  -- asking flared about itself) and the stats probes travel via the API
  -- server. So a node can be Ready and serving clients perfectly while the
  -- operator cannot push topology to it — it then runs on a STALE MAP (wrong
  -- roles) until the path heals, which is hazard H4 with no detector.
  -- ALERT ONLY, never fed into dead detection: unreachability is a loss of
  -- OUR feedback and the fault may be on our side, so failing over a master
  -- we merely cannot see is the unsafe control action (see
  -- docs/STPA-node-state.md). Probed every ~30s, not per tick.
  let reachSlot := (← IO.monoMsNow) / 30000
  if reachSlot != (← reachSlotRef.get) then
    reachSlotRef.set reachSlot
    let addrs ← podAddrsRef.get
    let prevUnreach ← unreachCyclesRef.get
    let mut newUnreach : List (String × Nat) := []
    for (key, ip) in addrs do
      if ip != "" then
        if !(← Server.probeNodeReachable ip 12121) then
          let streak := ((prevUnreach.lookup key).getD 0) + 1
          newUnreach := newUnreach ++ [(key, streak)]
          if streak == 1 || streak % 10 == 0 then
            IO.eprintln s!"[flare-operator] CRITICAL: node {key} ({ip}:12121) is READY but the OPERATOR cannot connect to it ({streak} consecutive probes, ~{streak * 30}s). Topology pushes are not landing — that node is running on a stale map. NOT failing it over: the fault may be on our side. See RUNBOOK #node-unreachable"
    unreachCyclesRef.set newUnreach
    metrics.unreachableNodes.set newUnreach.length.toFloat

  -- 5. Handle rocksdb config propagation + cluster replication migration
  let crd ← crdRef.get
  handleRocksdbConfig crd crName ns pendingConfRef
  handleClusterReplication crd (← stateRef.get) migrationRef pendingConfRef masterSnapshotRef driftTickRef metrics crName ns

  -- 5a. Blue/green migrations (FlareMigration CRs whose spec.source is this
  -- cluster). One pure-FSM step per tick; all destructive transitions sit
  -- behind explicit spec approvals (machine-checked in Migration/Types.lean).
  try
    Migration.Controller.tick crName ns
  catch e =>
    IO.eprintln s!"[migration] tick error: {e}"

  -- 5b'. Migration-provisioned SELF-RETIRE (post-migration handoff). When
  -- this operator was created by a FlareMigration (marker env) and a
  -- HELM-managed successor operating the SAME cluster is Ready, delete our
  -- own Deployment+Service NOW: keeping the {cr}-operator-lease parked the
  -- successor pair in standby, so the index Service had no leader endpoint
  -- and the re-pointed StatefulSet crashlooped on "failed to connect to
  -- index server" (observed live; the crashloop kills then corrupted a
  -- replica's DB). Self-deletion releases the lease within one expiry.
  if (← IO.getEnv "FLARE_MIGRATION_PROVISIONED").isSome then
    try
      let successors ← kubectl ["get", "pods", "-n", ns,
        "-l", "app.kubernetes.io/name=flare-operator",
        "-o", "jsonpath={range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}|{.spec.containers[0].args}{\"\\n\"}{end}"]
      match successors with
      | .error _ => pure ()
      | .ok out =>
        let found := out.splitOn "\n" |>.any fun line =>
          let parts := line.splitOn "|"
          match parts with
          | [ready, argsStr] =>
            -- args are rendered as a JSON array; require the exact adjacent
            -- pair ["--cluster-name","<our cr>"] so a name that happens to
            -- be a substring of another arg can't false-positive.
            ready.trim == "True"
              && (argsStr.splitOn s!"--cluster-name\",\"{crName}\"").length > 1
          | _ => false
        if found then
          IO.eprintln s!"[migration] helm successor for '{crName}' is Ready -> SELF-RETIRING (deleting {crName}-operator Deployment+Service; the lease hands over within one expiry)"
          let _ ← kubectl ["delete", "deployment", s!"{crName}-operator", "-n", ns, "--ignore-not-found"]
          let _ ← kubectl ["delete", "service", s!"{crName}-operator", "-n", ns, "--ignore-not-found"]
    catch e =>
      IO.eprintln s!"[migration] self-retire check error: {e}"
  -- Publish the migration phase/desired to Prometheus (-> Grafana Cloud).
  let migPhase ← migrationRef.get
  let phaseNum : Float := match migPhase with
    | .None => 0.0 | .Dumping => 1.0 | .Forwarding => 2.0
  let desiredNum : Float :=
    if !crd.spec.clusterReplication.enabled then 0.0
    else if crd.spec.clusterReplication.mode == "forward" then 2.0 else 1.0
  updateMigrationMetrics metrics phaseNum desiredNum

  -- 5b. Pending-config re-signal (see handleRocksdbConfig): one non-blocking
  -- propagation check per tick; SIGHUP again once the mounted files caught
  -- up. Give up with a loud warning after ~5 minutes of ticks.
  match ← pendingConfRef.get with
  | none => pure ()
  | some (needle, ticks) =>
    if ← Bridge.confLandedOnAllPods crName ns needle then
      sendSighupToPods crName ns
      pendingConfRef.set none
      IO.eprintln s!"[flare-operator] config propagation confirmed after {ticks + 1} tick(s), SIGHUP re-sent"
    else if ticks >= 60 then
      pendingConfRef.set none
      IO.eprintln s!"[flare-operator] WARNING: extra.conf update not observed on all pods after {ticks + 1} ticks — giving up re-signal; config may be applied only partially"
    else
      pendingConfRef.set (some (needle, ticks + 1))

-- ===========================================================================
-- Main Reconcile Loop (Legacy - for comparison/fallback)
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
      match ← acquireLease leaseName ns identity lease.holderIdentity lease.resourceVersion leaseDurationSeconds (lease.transitions + 1) with
      | .ok () => return true
      | .error _ => return false
    else
      return false  -- another pod holds a valid lease

-- ===========================================================================
-- Entry Point
-- ===========================================================================

/-- Set this pod's `flare.gree.net/role` label (leader/standby). The index
    Service selects `role=leader`, so this label — not readiness — is what
    routes flared's index traffic to the elected leader. Best-effort by
    design: callers decide how loudly to react, and the leader loop
    re-asserts it every tick so a transient API failure self-heals. -/
private def setRoleLabel (identity ns role : String) : IO Bool := do
  match ← Kubectl.kubectl ["label", "pod", identity,
      s!"flare.gree.net/role={role}", "--overwrite", "-n", ns] with
  | .ok _ => return true
  | .error e =>
    IO.eprintln s!"[flare-operator] WARNING: failed to label pod {identity} role={role}: {e}"
    return false

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

  -- 1-operator = 1-namespace/1-cluster is a hard design assumption: this
  -- process serves the flarei protocol for exactly ONE FlareCluster. A CR
  -- with any other name in this namespace is silently ignored by design —
  -- but silence misleads (the chart's README once told users to create a
  -- differently-named CR that nothing would ever manage; external review
  -- P1-1). Say it loudly at startup.
  match ← listFlareClusters ns with
  | .error _ => pure ()
  | .ok crs =>
    for (otherName, _) in crs do
      if otherName != crName then
        IO.eprintln s!"[flare-operator] WARNING: FlareCluster '{otherName}' exists in namespace '{ns}' but this operator only manages '{crName}' (clusterName in the helm values). It will be IGNORED — deploy a second operator release or fix clusterName."

  let leaseName := s!"{crName}-operator-lease"

  -- The health server must be up BEFORE the follower loop: a standby
  -- replica (replicaCount > 1) blocks in phase 1 indefinitely, and with no
  -- /healthz listener the liveness probe kills it every failure window —
  -- an exit-137 crashloop observed on the first 2-replica deployment.
  -- While waiting for the lease: /healthz 200 (alive), /readyz 503 (not
  -- leader), which keeps the standby out of the Service but out of the
  -- kubelet's gun.
  -- Ports are env-configurable so the chart's values actually take effect
  -- (they previously only changed the containerPort declarations while the
  -- servers stayed hardcoded — ServiceMonitor got connection refused;
  -- external review P2-6). The chart injects FLARE_*_PORT from its values.
  let healthPort := (((← IO.getEnv "FLARE_HEALTH_PORT").bind (·.toNat?)).getD 8080).toUInt16
  let metricsPort := (((← IO.getEnv "FLARE_METRICS_PORT").bind (·.toNat?)).getD 9090).toUInt16
  let healthStatus ← HealthStatus.new
  startHealthServerBackground healthStatus { port := healthPort }
  IO.eprintln s!"[flare-operator] health check server started on port {healthPort} (leader=false)"

  -- Pod labels survive container restarts: a crashed ex-leader would keep
  -- routing index traffic to itself while it is back in the follower loop.
  -- Reset to standby before ever trying for the lease.
  let _ ← setRoleLabel identity ns "standby"

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

  healthStatus.setLeader true  -- We just acquired the lease
  IO.eprintln s!"[flare-operator] health status: leader=true"

  -- Claim the index traffic: the Service selects role=leader. Loud on
  -- failure (a leader without the label serves nobody); the reconcile loop
  -- re-asserts the label every tick until it sticks.
  if !(← setRoleLabel identity ns "leader") then
    IO.eprintln s!"[flare-operator] ERROR: leader label not set — index Service will not route here yet"

  -- Initialize metrics
  let metrics ← initMetrics
  IO.eprintln s!"[flare-operator] metrics initialized"

  -- Start metrics HTTP server in background
  startMetricsServerBackground metrics crName { port := metricsPort }
  IO.eprintln s!"[flare-operator] metrics server started on port {metricsPort}"

  -- Initialize shared state
  let stateRef ← IO.mkRef FlareClusterState.default

  -- Try to load persisted state from ConfigMap
  let cmName := s!"{crName}-node-map"
  match ← readFlaredConfigMap cmName ns with
  | .error _ => IO.eprintln s!"[flare-operator] no persisted state found, starting fresh"
  | .ok data =>
    if data.trim != "" then
      let loaded := FlareClusterState.fromNodeMapData data
      -- MIGRATION: maps persisted by pre-thread operators load every node at
      -- the shared default 16, which collapses flared's per-destination proxy
      -- pools into one (misrouted forwards/relays). Re-number duplicates once;
      -- the version bump makes flared adopt the corrected channels.
      let loaded := loaded.normalizeThreadTypes
      let loaded := loaded.rebuildPartitionMap
      stateRef.set loaded
      IO.eprintln s!"[flare-operator] loaded {loaded.nodeMap.length} nodes from ConfigMap (resuming at broadcast version {loaded.nodeMapVersion})"

  -- FENCING: fold the leadership generation (Lease spec.leaseTransitions,
  -- bumped on every takeover) into the broadcast version space:
  --   version := max(resumed, generation * 2^32)
  -- flared already ignores any node sync whose version is not newer than
  -- the last it accepted, and that counter is persisted across our own
  -- restarts — so with generation as the high bits, EVERY broadcast from a
  -- deposed leader (lower generation ⇒ lower version, whatever its
  -- counter) is rejected by any flared that has heard the new leader.
  -- The dual-leader window (a hung iteration outliving the lease; an ack
  -- landing on a dying leader) loses its ability to influence flared maps
  -- — no wire-format change, old flared gets the fence for free. The low
  -- 32 bits allow ~95 years of ticks per generation before overflow.
  match ← getLease leaseName ns with
  | .error e =>
    IO.eprintln s!"[flare-operator] WARNING: could not read lease generation ({e}) — broadcasts stay in the resumed version space"
  | .ok lease =>
    let genBase := lease.transitions * 4294967296
    let cur ← stateRef.get
    if genBase > cur.nodeMapVersion then
      stateRef.set { cur with nodeMapVersion := genBase }
    IO.eprintln s!"[flare-operator] leadership generation {lease.transitions} — broadcast versions fenced at ≥ {max genBase cur.nodeMapVersion}"
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
      -- Sentinel spec while the CR is missing: partitions = 0 makes every
      -- assignment function a natural no-op (nothing to need a master or
      -- slave), so early registrations park as proxies instead of being
      -- MISASSIGNED against a fabricated 1x1 layout. The reconcile loop
      -- refetches every tick and swaps the real spec in as soon as the CR
      -- exists; the FSM then assigns the parked proxies correctly.
      let mut result : FlareClusterView := {
        metadata := { name := some crName, «namespace» := some ns }
        spec := { partitions := 0, replicas := 0 }
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
        -- Not fatal: an operator legitimately starts before its CR exists
        -- (fresh install order). With the 0-partition sentinel nothing can
        -- be misassigned in the meantime — but say so every startup, and
        -- the reconcile loop will keep retrying each tick.
        IO.eprintln s!"[flare-operator] WARNING: no FlareCluster spec yet — parking registrations as proxies until it appears (refetching every tick)"
      pure result
  let crdRef ← IO.mkRef initialCrd
  -- Always start from None phase - operator manages migration state internally
  -- Restore the migration phase from CR status: an operator restart during
  -- an active migration must not forget it (the previous version always
  -- started at None, so a restart mid-Dumping silently orphaned the
  -- migration — external review P1-4).
  let restoredPhase ← Bridge.readMigrationPhase crName ns
  if restoredPhase != MigrationPhase.None then
    IO.eprintln s!"[flare-operator] restored migrationPhase={restoredPhase.toString} from CR status"
  let migrationRef ← IO.mkRef restoredPhase

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
  let unreadyCyclesRef ← IO.mkRef ([] : List (String × Nat))
  let podKeysRef ← IO.mkRef ([] : List String)
  let podAddrsRef ← IO.mkRef ([] : List (String × String))
  let unreachCyclesRef ← IO.mkRef ([] : List (String × Nat))
  let reachSlotRef ← IO.mkRef (0 : Nat)
  -- Replica-repair ledger (SC-03 / SAF-05): restored from the FlareCluster
  -- status so a repair in flight, and the drop counters it is judged
  -- against, survive this process.
  -- Prepare episodes for the activation-evidence repair (SC-04 / SAF-03).
  let episodesRef ← IO.mkRef ([] : List SyncEvidence.Episode)
  -- Item 4: "no ledger" and "could not read the ledger" are different.
  -- Starting from an empty ledger over a pending request would lose it and
  -- re-baseline the counters, so a failed read leaves the ledger UNAVAILABLE:
  -- no repair action and no drop accounting run until a read succeeds
  -- (retried here briefly, then at the top of every pass).
  let ledgerRef ← IO.mkRef ({} : ReplicaRepair.Ledger)
  let ledgerAvailableRef ← IO.mkRef false
  let ledgerDirtyRef ← IO.mkRef false
  for attempt in [0:15] do
    if !(← ledgerAvailableRef.get) then
      match ← Bridge.readRepairLedger crName ns with
      | .ok (some l) =>
        ledgerRef.set l; ledgerAvailableRef.set true
        IO.eprintln s!"[flare-operator] replica repair ledger restored from status: {l.summary} ({l.counters.length} counter(s))"
      | .ok none =>
        ledgerAvailableRef.set true
        IO.eprintln "[flare-operator] replica repair ledger: nothing in status, starting fresh (first observation will record baselines only)"
      | .error e =>
        IO.eprintln s!"[flare-operator] replica repair ledger read failed (attempt {attempt + 1}/15): {e}"
        IO.sleep 2000
  if !(← ledgerAvailableRef.get) then
    IO.eprintln "[flare-operator] WARNING: replica repair ledger UNAVAILABLE at start; repair actions and drop accounting are HELD until a read succeeds — never starting from an empty ledger over a possibly pending request"
  let pendingBroadcastRef ← IO.mkRef (none : Option Nat)
  let downCyclesRef ← IO.mkRef ([] : List (String × Nat))
  let emptyMasterStreakRef ← IO.mkRef ([] : List (String × Nat))
  let probeSlotRef ← IO.mkRef (0 : Nat)
  -- Persistent breaker-trip flag (input to the reset hysteresis).
  let trippedRef ← IO.mkRef false
  let pendingConfRef ← IO.mkRef (none : Option (String × Nat))
  let driftTickRef ← IO.mkRef (0 : Nat)
  -- Master set captured when a cluster-replication migration starts; a change
  -- mid-migration triggers a fail-safe abort (see handleClusterReplication).
  let masterSnapshotRef ← IO.mkRef (none : Option (List String))

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
      -- Best-effort step-down: stop attracting index traffic before the
      -- replacement leader labels itself. If the API is unreachable this
      -- fails too — the pod exits and the boot-time reset covers it.
      let _ ← setRoleLabel identity ns "standby"
      -- This has to END THE PROCESS, and `throw` did not. The generated C
      -- `main` runs `lean_finalize_task_manager()` before it reports an
      -- uncaught error, and that call waits for every outstanding task —
      -- the TCP, health and metrics servers here, none of which return. The
      -- result was a pod that logged "exiting", kept passing /healthz
      -- (process-alive only) and /readyz (a non-leader is "ready"), owned no
      -- lease and ran no reconcile loop, for ever: with one replica a
      -- leaderless cluster, with two a silent loss of the standby. Found by
      -- the SAF-01 takeover test (CHECK-01), which forces exactly this path
      -- and then requires recovery. `exit` terminates regardless of threads.
      (← IO.getStderr).flush
      IO.Process.exit 1
    -- Self-healing label assert: a leader whose label patch failed (or was
    -- stripped externally) reclaims the index Service every tick.
    let _ ← setRoleLabel identity ns "leader"

    -- Time the reconcile loop
    let startTime ← IO.monoMsNow
    try
      -- Use FSM-driven reconcile (complete implementation with all 5 requirements)
      reconcileOnceFSM stateRef crdRef migrationRef graceCyclesRef trippedRef prepareCyclesRef unreadyCyclesRef podKeysRef podAddrsRef unreachCyclesRef reachSlotRef ledgerRef ledgerAvailableRef ledgerDirtyRef episodesRef pendingBroadcastRef downCyclesRef emptyMasterStreakRef probeSlotRef pendingConfRef masterSnapshotRef driftTickRef metrics leaseName identity crName ns
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

    -- NOTE: the operator no longer scrapes/re-exports flared stats. Each
    -- flared serves its own /metrics (PodMonitor scrapes pods directly), so
    -- data-plane observability does not share the control plane's fate.

    IO.sleep (interval * 1000).toUInt32

end FlareOperator

def main (args : List String) : IO Unit :=
  FlareOperator.main args
