/-
  Prometheus.lean - Prometheus metrics exporter for observability

  Exposes metrics on HTTP port 9090 in Prometheus text format:
  - Reconciliation duration
  - Node map version
  - Dead nodes detected
  - Topology broadcasts sent
  - Node counts by role and state
-/

import FlareOperator.K8s.FlareCluster

namespace FlareOperator.Metrics.Prometheus

open FlareOperator.K8s

/-! ## Metric Types -/

/-- Counter: monotonically increasing value -/
structure Counter where
  value : IO.Ref Nat
  deriving Nonempty

/-- Gauge: value that can go up or down -/
structure Gauge where
  value : IO.Ref Float
  deriving Nonempty

/-- Histogram bucket for duration tracking -/
structure HistogramBucket where
  le : Float  -- Less than or equal to (upper bound)
  count : IO.Ref Nat
  deriving Nonempty

/-- Histogram: distribution of values -/
structure Histogram where
  buckets : List HistogramBucket
  sum : IO.Ref Float
  count : IO.Ref Nat
  deriving Nonempty

/-! ## Metric Collection -/

/-- All operator metrics -/
structure OperatorMetrics where
  -- Histogram: reconcile loop duration in seconds
  reconcileDuration : Histogram

  -- Gauge: current node map version
  nodeMapVersion : Gauge

  -- Counter: total dead nodes detected
  deadNodesDetected : Counter

  -- Counter: total topology broadcasts sent
  topologyBroadcasts : Counter

  -- Gauges: node counts by role and state
  masterActiveCount : Gauge
  masterPrepareCount : Gauge
  slaveActiveCount : Gauge
  slavePrepareCount : Gauge
  proxyCount : Gauge

  -- Gauge: nodes stuck in Prepare beyond the watchdog threshold. Alert-only:
  -- the operator never auto-demotes a reconstructing node (large datasets
  -- legitimately reconstruct for hours), so this gauge is the signal for a
  -- human to investigate a stalled reconstruction.
  prepareStuckCount : Gauge

  -- Gauge: nodes whose POD IS PRESENT but which stopped being Ready long
  -- enough to be treated as dead (flared segfaulted or wedged). Pod
  -- existence used to be the operator's only liveness signal, so these were
  -- invisible AND undetected — a crashed master got no failover. Page on it:
  -- unlike a vanished pod (rescheduling, routine) a live pod that stops
  -- serving means the process itself is broken.
  unhealthyNodes : Gauge

  -- Gauge: nodes sitting Down while their pod is present. A Down node only
  -- leaves that state by re-registering (i.e. flared restarting), so this is
  -- the "stuck, needs a pod restart" population; the operator restarts them
  -- itself once every partition has an Active master.
  stuckDownNodes : Gauge

  -- Gauge: nodes the OPERATOR cannot open a TCP connection to, while K8s
  -- still reports their pod Ready. The node is probably serving clients
  -- fine; what is broken is our ability to PUSH topology to it, so it runs
  -- on a stale map (wrong roles) until the path heals. Never fed into dead
  -- detection on purpose — the fault may be on the operator's side, and
  -- failing over a master we merely cannot see is the unsafe action.
  unreachableNodes : Gauge

  -- Gauge: the largest master↔slave curr_items gap seen in the last probe,
  -- as a FRACTION of the master's count. Live replication is op-level
  -- proxying with no per-write acknowledgement, so a dropped or refused
  -- replica write leaves the replica quietly behind until it reconstructs;
  -- nothing else compares the two copies at all. A count comparison is
  -- coarse — equal counts do not prove equal CONTENT — but it catches the
  -- magnitude of a real divergence, which is what went unnoticed for 12
  -- days on pf-dev (~10k stale keys on the slave).
  replicaKeyDelta : Gauge

  -- Gauge: CRD partitions with no Active master, counted per partition
  -- index. The older signal for this was cluster-wide arithmetic
  -- (desired_partitions - active_masters), which a stale master sitting at
  -- an out-of-range partition index could offset — masking a genuinely
  -- masterless partition. This counts the partitions themselves.
  masterlessPartitions : Gauge

  -- Gauge: draining masters the drain guard kept because NO promotable
  -- successor exists. CRITICAL: each is a partition that loses its only
  -- data-bearing node when the pod's grace period expires; the operator
  -- cannot recover it (tmpfs reseeds rewind to the last S3 backup). A human
  -- must decide (e.g. trigger a final backup) — page immediately.
  drainNoSuccessor : Gauge

  -- Gauge: 1 while the blast-radius circuit breaker is tripped (the FSM's
  -- last pass ended in EmergencyPaused), else 0. Page on this: it means a
  -- suspected AZ-scale outage with automatic failover intentionally halted.
  circuitBreakerTripped : Gauge

  -- Gauge: partitions requested by the CRD. Lets alerting compare
  -- masters(active) against the DESIRED count instead of a hardcoded one.
  partitionsDesired : Gauge

  -- Cluster-replication (Blue/Green migration) observability, so the phase is
  -- visible from Grafana Cloud and the user can watch it to decide when to
  -- advance the mode / cut over. Numeric encodings (see HELP in exportMetrics):
  --   migrationPhase   applied:  0=none 1=dumping   2=forwarding
  --   migrationDesired declared: 0=none 1=duplicate 2=forward
  -- A gap between them (e.g. desired=2 forward while phase=1 dumping) means the
  -- operator is still applying / the new mode hasn't propagated yet.
  migrationPhase : Gauge
  migrationDesired : Gauge

  -- Counter: cluster-replication migrations aborted because a partition master
  -- changed (failover/promotion) mid-migration. The operator NEVER blocks
  -- source-cluster failover; it fail-safe aborts the migration instead (a
  -- master change mid-dump/forward would leave the target inconsistent). Alert
  -- on any increase: the migration must be restarted after the cluster settles.
  migrationAborted : Counter

  -- NOTE: per-pod flared stats are NOT re-exported here anymore. Each flared
  -- serves its own /metrics natively (scraped by a PodMonitor), so data-plane
  -- observability shares the pod's fault domain — an operator outage no longer
  -- blanks every node's series at once, which used to make a collector failure
  -- indistinguishable from a real outage during triage.

  deriving Nonempty

/-! ## Initialization -/

/-- Create histogram with standard buckets for duration -/
def createDurationHistogram : IO Histogram := do
  let buckets ← [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0].mapM fun le => do
    let count ← IO.mkRef 0
    return { le := le, count := count }
  let sum ← IO.mkRef 0.0
  let count ← IO.mkRef 0
  return { buckets := buckets, sum := sum, count := count }

/-- Initialize all metrics -/
def initMetrics : IO OperatorMetrics := do
  let reconcileDuration ← createDurationHistogram
  let nodeMapVersion ← IO.mkRef 0.0
  let deadNodesDetected ← IO.mkRef 0
  let topologyBroadcasts ← IO.mkRef 0
  let masterActiveCount ← IO.mkRef 0.0
  let masterPrepareCount ← IO.mkRef 0.0
  let slaveActiveCount ← IO.mkRef 0.0
  let slavePrepareCount ← IO.mkRef 0.0
  let proxyCount ← IO.mkRef 0.0
  let prepareStuckCount ← IO.mkRef 0.0
  let unhealthyNodes ← IO.mkRef 0.0
  let stuckDownNodes ← IO.mkRef 0.0
  let unreachableNodes ← IO.mkRef 0.0
  let replicaKeyDelta ← IO.mkRef 0.0
  let masterlessPartitions ← IO.mkRef 0.0
  let drainNoSuccessor ← IO.mkRef 0.0
  let circuitBreakerTripped ← IO.mkRef 0.0
  let partitionsDesired ← IO.mkRef 0.0
  let migrationPhase ← IO.mkRef 0.0
  let migrationDesired ← IO.mkRef 0.0
  let migrationAborted ← IO.mkRef 0

  return {
    reconcileDuration := reconcileDuration
    nodeMapVersion := { value := nodeMapVersion }
    deadNodesDetected := { value := deadNodesDetected }
    topologyBroadcasts := { value := topologyBroadcasts }
    masterActiveCount := { value := masterActiveCount }
    masterPrepareCount := { value := masterPrepareCount }
    slaveActiveCount := { value := slaveActiveCount }
    slavePrepareCount := { value := slavePrepareCount }
    proxyCount := { value := proxyCount }
    prepareStuckCount := { value := prepareStuckCount }
    unhealthyNodes := { value := unhealthyNodes }
    stuckDownNodes := { value := stuckDownNodes }
    unreachableNodes := { value := unreachableNodes }
    replicaKeyDelta := { value := replicaKeyDelta }
    masterlessPartitions := { value := masterlessPartitions }
    drainNoSuccessor := { value := drainNoSuccessor }
    circuitBreakerTripped := { value := circuitBreakerTripped }
    partitionsDesired := { value := partitionsDesired }
    migrationPhase := { value := migrationPhase }
    migrationDesired := { value := migrationDesired }
    migrationAborted := { value := migrationAborted }
  }

/-! ## Metric Update Functions -/

/-- Increment counter -/
def Counter.inc (c : Counter) : IO Unit := do
  c.value.modify (· + 1)

/-- Set gauge value -/
def Gauge.set (g : Gauge) (val : Float) : IO Unit := do
  g.value.set val

/-- Observe histogram value (e.g., duration) -/
def Histogram.observe (h : Histogram) (val : Float) : IO Unit := do
  -- Update sum and count
  h.sum.modify (· + val)
  h.count.modify (· + 1)

  -- Update buckets
  for bucket in h.buckets do
    if val <= bucket.le then
      bucket.count.modify (· + 1)

/-- Record reconcile duration -/
def recordReconcileDuration (metrics : OperatorMetrics) (durationSeconds : Float) : IO Unit := do
  metrics.reconcileDuration.observe durationSeconds

/-- Update node map version -/
def updateNodeMapVersion (metrics : OperatorMetrics) (version : Nat) : IO Unit := do
  metrics.nodeMapVersion.set version.toFloat

/-- Increment dead nodes counter -/
def recordDeadNode (metrics : OperatorMetrics) : IO Unit := do
  metrics.deadNodesDetected.inc

/-- Increment topology broadcast counter -/
def recordTopologyBroadcast (metrics : OperatorMetrics) : IO Unit := do
  metrics.topologyBroadcasts.inc

/-- Update node counts from cluster state -/
def updateNodeCounts (metrics : OperatorMetrics) (state : FlareClusterState) : IO Unit := do
  let nodes := state.nodeMap.map Prod.snd

  let masterActive := nodes.filter (fun n => n.role == FlareRole.Master && n.state == FlareState.Active)
  let masterPrepare := nodes.filter (fun n => n.role == FlareRole.Master && (n.state == FlareState.Prepare || n.state == FlareState.Ready))
  let slaveActive := nodes.filter (fun n => n.role == FlareRole.Slave && n.state == FlareState.Active)
  let slavePrepare := nodes.filter (fun n => n.role == FlareRole.Slave && (n.state == FlareState.Prepare || n.state == FlareState.Ready))
  let proxy := nodes.filter (fun n => n.role == FlareRole.Proxy)

  metrics.masterActiveCount.set masterActive.length.toFloat
  metrics.masterPrepareCount.set masterPrepare.length.toFloat
  metrics.slaveActiveCount.set slaveActive.length.toFloat
  metrics.slavePrepareCount.set slavePrepare.length.toFloat
  metrics.proxyCount.set proxy.length.toFloat

/-- Set the cluster-replication phase/desired gauges. Callers pass the numeric
    encodings (phase: 0=none 1=dumping 2=forwarding; desired: 0=none 1=duplicate
    2=forward) computed where the MigrationPhase / spec are in scope, so this
    module needs no dependency on those types. -/
def updateMigrationMetrics (metrics : OperatorMetrics) (phaseNum desiredNum : Float) : IO Unit := do
  metrics.migrationPhase.set phaseNum
  metrics.migrationDesired.set desiredNum

/-! ## Prometheus Text Format Export -/

/-- Format counter in Prometheus text format -/
def formatCounter (name : String) (labels : String) (value : Nat) : String :=
  name ++ "{" ++ labels ++ "} " ++ toString value ++ "\n"

/-- Format gauge in Prometheus text format -/
def formatGauge (name : String) (labels : String) (value : Float) : String :=
  name ++ "{" ++ labels ++ "} " ++ toString value ++ "\n"

/-- Format histogram in Prometheus text format -/
def formatHistogram (name : String) (labels : String) (h : Histogram) : IO String := do
  let mut output := ""

  -- Buckets
  for bucket in h.buckets do
    let count ← bucket.count.get
    let bucketLabels := if labels.isEmpty
      then s!"le=\"{bucket.le}\""
      else labels ++ ",le=\"" ++ toString bucket.le ++ "\""
    output := output ++ name ++ "_bucket{" ++ bucketLabels ++ "} " ++ toString count ++ "\n"

  -- +Inf bucket
  let totalCount ← h.count.get
  let infLabels := if labels.isEmpty
    then "le=\"+Inf\""
    else labels ++ ",le=\"+Inf\""
  output := output ++ name ++ "_bucket{" ++ infLabels ++ "} " ++ toString totalCount ++ "\n"

  -- Sum
  let sum ← h.sum.get
  output := output ++ name ++ "_sum{" ++ labels ++ "} " ++ toString sum ++ "\n"

  -- Count
  output := output ++ name ++ "_count{" ++ labels ++ "} " ++ toString totalCount ++ "\n"

  return output

/-- Export all metrics in Prometheus text format -/
def exportMetrics (metrics : OperatorMetrics) (clusterName : String) : IO String := do
  let labels := "cluster=\"" ++ clusterName ++ "\""
  let mut output := ""

  -- Reconcile duration (histogram)
  output := output ++ "# HELP flare_operator_reconcile_duration_seconds Reconcile loop duration in seconds\n"
  output := output ++ "# TYPE flare_operator_reconcile_duration_seconds histogram\n"
  let histData ← formatHistogram "flare_operator_reconcile_duration_seconds" labels metrics.reconcileDuration
  output := output ++ histData

  -- Node map version (gauge)
  output := output ++ "# HELP flare_operator_node_map_version Current node map version\n"
  output := output ++ "# TYPE flare_operator_node_map_version gauge\n"
  let version ← metrics.nodeMapVersion.value.get
  output := output ++ formatGauge "flare_operator_node_map_version" labels version

  -- Dead nodes detected (counter)
  output := output ++ "# HELP flare_operator_dead_nodes_detected_total Total dead nodes detected\n"
  output := output ++ "# TYPE flare_operator_dead_nodes_detected_total counter\n"
  let deadNodes ← metrics.deadNodesDetected.value.get
  output := output ++ formatCounter "flare_operator_dead_nodes_detected_total" labels deadNodes

  -- Topology broadcasts (counter)
  output := output ++ "# HELP flare_operator_topology_broadcasts_total Total topology broadcasts sent\n"
  output := output ++ "# TYPE flare_operator_topology_broadcasts_total counter\n"
  let broadcasts ← metrics.topologyBroadcasts.value.get
  output := output ++ formatCounter "flare_operator_topology_broadcasts_total" labels broadcasts

  -- Node counts by role and state (gauges)
  output := output ++ "# HELP flare_operator_nodes_total Number of nodes by role and state\n"
  output := output ++ "# TYPE flare_operator_nodes_total gauge\n"

  let masterActive ← metrics.masterActiveCount.value.get
  output := output ++ formatGauge "flare_operator_nodes_total" (labels ++ ",role=\"master\",state=\"active\"") masterActive

  let masterPrepare ← metrics.masterPrepareCount.value.get
  output := output ++ formatGauge "flare_operator_nodes_total" (labels ++ ",role=\"master\",state=\"prepare\"") masterPrepare

  let slaveActive ← metrics.slaveActiveCount.value.get
  output := output ++ formatGauge "flare_operator_nodes_total" (labels ++ ",role=\"slave\",state=\"active\"") slaveActive

  let slavePrepare ← metrics.slavePrepareCount.value.get
  output := output ++ formatGauge "flare_operator_nodes_total" (labels ++ ",role=\"slave\",state=\"prepare\"") slavePrepare

  let proxy ← metrics.proxyCount.value.get
  output := output ++ formatGauge "flare_operator_nodes_total" (labels ++ ",role=\"proxy\",state=\"active\"") proxy

  -- Prepare-stuck watchdog (gauge)
  output := output ++ "# HELP flare_operator_nodes_prepare_stuck Nodes in Prepare longer than the watchdog threshold\n"
  output := output ++ "# TYPE flare_operator_nodes_prepare_stuck gauge\n"
  let prepareStuck ← metrics.prepareStuckCount.value.get
  output := output ++ formatGauge "flare_operator_nodes_prepare_stuck" labels prepareStuck

  -- Unhealthy nodes: pod present but not serving (gauge, CRITICAL)
  output := output ++ "# HELP flare_operator_nodes_unhealthy Nodes whose pod is present but stopped being Ready long enough to be treated as dead (flared crashed or wedged)\n"
  output := output ++ "# TYPE flare_operator_nodes_unhealthy gauge\n"
  let unhealthy ← metrics.unhealthyNodes.value.get
  output := output ++ formatGauge "flare_operator_nodes_unhealthy" labels unhealthy

  -- Stuck Down nodes: Down but their pod is alive (gauge)
  output := output ++ "# HELP flare_operator_nodes_down_stuck Nodes sitting Down while their pod is present (only a flared restart clears Down)\n"
  output := output ++ "# TYPE flare_operator_nodes_down_stuck gauge\n"
  let stuckDown ← metrics.stuckDownNodes.value.get
  output := output ++ formatGauge "flare_operator_nodes_down_stuck" labels stuckDown

  -- Nodes unreachable from the operator (gauge)
  output := output ++ "# HELP flare_operator_nodes_unreachable Ready nodes the operator cannot open a TCP connection to (topology pushes are not landing; the node runs on a stale map)\n"
  output := output ++ "# TYPE flare_operator_nodes_unreachable gauge\n"
  let unreachable ← metrics.unreachableNodes.value.get
  output := output ++ formatGauge "flare_operator_nodes_unreachable" labels unreachable

  -- Replica divergence: |master - slave| / master from the last probe (gauge)
  output := output ++ "# HELP flare_operator_replica_key_delta Largest master-to-slave curr_items gap as a fraction of the master's count (coarse divergence signal; equal counts do not prove equal content)\n"
  output := output ++ "# TYPE flare_operator_replica_key_delta gauge\n"
  let keyDelta ← metrics.replicaKeyDelta.value.get
  output := output ++ formatGauge "flare_operator_replica_key_delta" labels keyDelta

  -- Masterless partitions, counted per partition index (gauge, CRITICAL)
  output := output ++ "# HELP flare_operator_partitions_masterless CRD partitions with no Active master (per-partition; not cluster-wide arithmetic that a stale out-of-range master can offset)\n"
  output := output ++ "# TYPE flare_operator_partitions_masterless gauge\n"
  let masterless ← metrics.masterlessPartitions.value.get
  output := output ++ formatGauge "flare_operator_partitions_masterless" labels masterless

  -- Drain-no-successor (gauge, CRITICAL)
  output := output ++ "# HELP flare_operator_drain_no_successor Draining masters with no promotable successor (partition loses its only data-bearing node at grace expiry)\n"
  output := output ++ "# TYPE flare_operator_drain_no_successor gauge\n"
  let drainNoSucc ← metrics.drainNoSuccessor.value.get
  output := output ++ formatGauge "flare_operator_drain_no_successor" labels drainNoSucc

  -- Circuit breaker state (gauge)
  output := output ++ "# HELP flare_operator_circuit_breaker_tripped 1 while failover is paused by the blast-radius breaker\n"
  output := output ++ "# TYPE flare_operator_circuit_breaker_tripped gauge\n"
  let tripped ← metrics.circuitBreakerTripped.value.get
  output := output ++ formatGauge "flare_operator_circuit_breaker_tripped" labels tripped

  -- Desired partitions from the CRD (gauge)
  output := output ++ "# HELP flare_operator_partitions_desired Partitions requested by the FlareCluster spec\n"
  output := output ++ "# TYPE flare_operator_partitions_desired gauge\n"
  let desired ← metrics.partitionsDesired.value.get
  output := output ++ formatGauge "flare_operator_partitions_desired" labels desired

  -- Cluster-replication migration (Blue/Green) state.
  output := output ++ "# HELP flare_operator_migration_phase Applied migration phase (0=none 1=dumping 2=forwarding)\n"
  output := output ++ "# TYPE flare_operator_migration_phase gauge\n"
  let migPhase ← metrics.migrationPhase.value.get
  output := output ++ formatGauge "flare_operator_migration_phase" labels migPhase

  output := output ++ "# HELP flare_operator_migration_desired Declared migration mode from spec (0=none 1=duplicate 2=forward)\n"
  output := output ++ "# TYPE flare_operator_migration_desired gauge\n"
  let migDesired ← metrics.migrationDesired.value.get
  output := output ++ formatGauge "flare_operator_migration_desired" labels migDesired

  output := output ++ "# HELP flare_operator_migration_aborted_total Migrations aborted due to a master change mid-migration\n"
  output := output ++ "# TYPE flare_operator_migration_aborted_total counter\n"
  let migAborted ← metrics.migrationAborted.value.get
  output := output ++ formatCounter "flare_operator_migration_aborted_total" labels migAborted

  return output

/-! ## HTTP Server -/

/-- Simple HTTP response -/
structure HttpResponse where
  statusCode : Nat
  statusText : String
  contentType : String
  body : String

/-- Create 200 OK response with metrics -/
def metricsResponse (body : String) : HttpResponse :=
  { statusCode := 200
    statusText := "OK"
    contentType := "text/plain; version=0.0.4"
    body := body }

/-- Create 404 Not Found response -/
def notFoundResponse : HttpResponse :=
  { statusCode := 404
    statusText := "Not Found"
    contentType := "text/plain"
    body := "404 Not Found\n" }

/-- Format HTTP response -/
def formatHttpResponse (resp : HttpResponse) : String :=
  s!"HTTP/1.1 {resp.statusCode} {resp.statusText}\r\n" ++
  s!"Content-Type: {resp.contentType}\r\n" ++
  s!"Content-Length: {resp.body.length}\r\n" ++
  "\r\n" ++
  resp.body

end FlareOperator.Metrics.Prometheus
