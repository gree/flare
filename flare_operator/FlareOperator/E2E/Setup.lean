/-
  E2E/Setup.lean - Common setup/teardown for E2E tests

  Provides cluster deployment, cleanup, and stability waiting helpers.
  Generates YAML for operator deployments, StatefulSets, and FlareCluster CRDs.
-/

import FlareOperator.E2E.Helpers

namespace FlareOperator.E2E.Setup

open FlareOperator.E2E.Helpers
open FlareOperator.Kubectl

/-- Configuration for a Flare cluster deployment.

    `storageBackend` selects which flared image and `--storage-type` flag
    to use. The default "tch" uses the existing `flare-node:test` image
    (Tokyo Cabinet, no RocksDB code compiled in). Setting it to "rocksdb"
    switches to `flare-node-rocksdb:test` which is built by
    `Dockerfile.flare-node-rocksdb` and has the RocksDB backend + WAL
    replication path compiled in. Only the rocksdb backend exposes the
    `rocksdb_*` stats that the G1/G2/G5/G10-stats tests assert on. -/
structure ClusterConfig where
  name : String
  «namespace» : String := "flare-system"
  partitions : Nat := 2
  replicas : Nat := 2
  operatorName : String := "flare-operator"
  debugPod : String := "debug-e2e"
  flarePort : Nat := 12121
  operatorPort : Nat := 12120
  /-- Storage backend: "tch" (default, Tokyo Cabinet) or "rocksdb". -/
  storageBackend : String := "tch"
  /-- Persist flared data on a PVC (volumeClaimTemplates) instead of the
      pod-local tmpdir. With a PVC the data directory survives pod
      recreation, so a partition can recover its data even when the master
      AND all its slaves die at once — the case replica promotion alone can
      never cover. Mirrors the production example
      helm/flare-operator/examples/flare-cluster-persistent.yaml. -/
  usePvc : Bool := false
  /-- PVC size request (only used when usePvc). Kind's default storage
      class (local-path) ignores the size, so keep it small. -/
  pvcSize : String := "1Gi"
  /-- Extra flared.conf lines baked into the INITIAL {name}-config ConfigMap,
      so pods BOOT with them applied by load(). Required for DB-reopen-only
      options (e.g. rocksdb-wal-ttl-seconds) that reload() deliberately
      refuses to hot-apply — patching the CRD after deploy can never apply
      those, and restarting the whole StatefulSet mid-suite churns every
      node through re-registration. -/
  extraFlaredConf : String := ""
  deriving Repr

/-- Image tag used for the flared container in this cluster. -/
def ClusterConfig.flaredImage (cfg : ClusterConfig) : String :=
  match cfg.storageBackend with
  | "rocksdb" => "flare-node-rocksdb:test"
  | _ => "flare-node:test"

/-- Generate a unique namespace name using timestamp to avoid test conflicts.
    Format: {baseName}-{timestamp-ms}
    Example: "flare-test-1710412345678" -/
def uniqueNamespace (baseName : String := "flare-test") : IO String := do
  let timestamp ← IO.monoMsNow
  pure s!"{baseName}-{timestamp}"

/-- Create a ClusterConfig with a unique namespace to ensure test isolation.
    This prevents cleanup race conditions between parallel or sequential test runs. -/
def ClusterConfig.withUniqueNamespace (cfg : ClusterConfig) : IO ClusterConfig := do
  let uniqueNs ← uniqueNamespace cfg.name
  pure { cfg with «namespace» := uniqueNs }

-- ===========================================================================
-- YAML Generation
-- ===========================================================================

/-- Generate ServiceAccount for the operator in the test namespace. -/
def serviceAccountYaml (cfg : ClusterConfig) : String :=
  let ns := cfg.«namespace»
  s!"apiVersion: v1
kind: ServiceAccount
metadata:
  name: flare-operator
  namespace: {ns}"

/-- Generate ClusterRoleBinding for the operator ServiceAccount in test namespace.
    This binds the global flare-operator ClusterRole (installed from the helm chart)
    to the namespace-specific ServiceAccount. -/
def clusterRoleBindingYaml (cfg : ClusterConfig) : String :=
  let ns := cfg.«namespace»
  let bindingName := s!"flare-operator-{ns}"
  s!"apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {bindingName}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flare-operator
subjects:
  - kind: ServiceAccount
    name: flare-operator
    namespace: {ns}"

/-- Generate operator Deployment + Service YAML. -/
def operatorDeploymentYaml (cfg : ClusterConfig) : String :=
  let name := cfg.operatorName
  let ns := cfg.«namespace»
  s!"apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  namespace: {ns}
  labels:
    app: {name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {name}
  template:
    metadata:
      labels:
        app: {name}
    spec:
      serviceAccountName: flare-operator
      containers:
        - name: flare-operator
          image: flare-operator:test
          imagePullPolicy: Never
          args:
            - \"--namespace\"
            - \"{ns}\"
            - \"--cluster-name\"
            - \"{cfg.name}\"
          ports:
            - containerPort: {cfg.operatorPort}
              name: flare-index
              protocol: TCP
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: {ns}
spec:
  selector:
    app: {name}
  ports:
    - port: {cfg.operatorPort}
      targetPort: flare-index
      protocol: TCP
  type: ClusterIP"

/-- Generate StatefulSet + headless Service YAML. -/
def statefulSetYaml (cfg : ClusterConfig) : String :=
  let cluster := cfg.name
  let ns := cfg.«namespace»
  let numPods := cfg.partitions * cfg.replicas
  let operatorSvc := s!"{cfg.operatorName}.{ns}.svc.cluster.local"
  let image := cfg.flaredImage
  -- Without a PVC the pod-local dir may contain leftovers from a previous
  -- container in the same sandbox, so we wipe it: a fresh pod must start
  -- with an empty data directory (TCH stores a single `.hdb` file; RocksDB
  -- stores a directory). WITH a PVC the whole point is that data survives
  -- pod recreation, so we only mkdir and never wipe.
  let dataDir := if cfg.usePvc then "/data/flare" else "/tmp/flare"
  -- RESTORE hook (PVC only): if the marker file exists it names a checkpoint
  -- directory (created by the flared `backup` op, a complete RocksDB dir);
  -- replace the live DB with it and consume the marker, then start flared.
  -- Restore procedure: write the marker on each pod's PVC, delete the pods.
  let prep := if cfg.usePvc then
      s!"if [ -f {dataDir}/RESTORE ]; then SRC=$(cat {dataDir}/RESTORE) && rm -rf {dataDir}/flare.rocksdb && cp -a $SRC {dataDir}/flare.rocksdb && rm -f {dataDir}/RESTORE; fi; mkdir -p {dataDir}"
    else
      s!"rm -rf {dataDir}/*.hdb {dataDir}/*.hdb.wal {dataDir}/rocksdb && mkdir -p {dataDir}"
  let storageFlag := s!"--storage-type={cfg.storageBackend}"
  let pvcMount := if cfg.usePvc then "
            - name: data
              mountPath: /data" else ""
  let pvcTemplates := if cfg.usePvc then s!"
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [\"ReadWriteOnce\"]
        resources:
          requests:
            storage: {cfg.pvcSize}" else ""
  s!"apiVersion: v1
kind: Service
metadata:
  name: {cluster}-nodes
  namespace: {ns}
  labels:
    app: flare
    cluster: {cluster}
spec:
  clusterIP: None
  selector:
    app: flare
    cluster: {cluster}
  ports:
    - port: {cfg.flarePort}
      targetPort: flare
      name: flare
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {cluster}-nodes
  namespace: {ns}
spec:
  serviceName: {cluster}-nodes
  replicas: {numPods}
  selector:
    matchLabels:
      app: flare
      cluster: {cluster}
  template:
    metadata:
      labels:
        app: flare
        cluster: {cluster}
    spec:
      terminationGracePeriodSeconds: 5
      containers:
        - name: flared
          image: {image}
          imagePullPolicy: Never
          command: [\"sh\", \"-c\", \"{prep} && exec flared --config=/etc/flared/extra.conf --data-dir {dataDir} --server-port {cfg.flarePort} --index-server-name {operatorSvc} --index-server-port {cfg.operatorPort} {storageFlag} --stderr\"]
          ports:
            - containerPort: {cfg.flarePort}
              name: flare
          volumeMounts:
            - name: flared-config
              mountPath: /etc/flared{pvcMount}
          livenessProbe:
            tcpSocket:
              port: {cfg.flarePort}
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          readinessProbe:
            tcpSocket:
              port: {cfg.flarePort}
            initialDelaySeconds: 5
            periodSeconds: 3
            failureThreshold: 4
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: flared-config
          configMap:
            name: {cluster}-config{pvcTemplates}"

/-- Generate FlareCluster CRD YAML. -/
def flareClusterCrdYaml (cfg : ClusterConfig) : String :=
  s!"apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: {cfg.name}
  namespace: {cfg.«namespace»}
spec:
  partitions: {cfg.partitions}
  replicas: {cfg.replicas}"

/-- Generate partition Service YAML for a single partition. -/
def partitionServiceYaml (cfg : ClusterConfig) (partIdx : Nat) : String :=
  s!"apiVersion: v1
kind: Service
metadata:
  name: {cfg.name}-{partIdx}
  namespace: {cfg.«namespace»}
spec:
  selector:
    statefulset.kubernetes.io/pod-name: {cfg.name}-nodes-0
  ports:
    - port: {cfg.flarePort}
      targetPort: {cfg.flarePort}"

-- ===========================================================================
-- Deploy / Cleanup
-- ===========================================================================

/-- Apply YAML string via kubectl with retry on transient etcd errors.

    Retries up to 3 times with 5s backoff when kubectl's stderr contains
    "etcdserver: request timed out" — this happens on loaded/restarting
    apiservers and is almost always transient.  Other failures (validation,
    conflicts, etc.) fail fast after the first attempt, printing the
    generated YAML's head so the rejected resource is identifiable. -/
private def applyYaml (yaml : String) : IO Unit := do
  let maxRetries := 3
  let mut lastErr := ""
  for _ in List.range (maxRetries + 1) do
    let result ← try
      IO.Process.output {
        cmd := "sh"
        args := #["-c", s!"cat <<'ENDOFYAML' | kubectl apply -f -\n{yaml}\nENDOFYAML"]
      }
    catch e =>
      IO.eprintln s!"# kubectl apply spawn error: {e}"
      throw (IO.userError s!"kubectl apply spawn error: {e}")
    if result.exitCode == 0 then return ()
    lastErr := result.stderr
    -- Transient etcd timeout → retry
    let isTransient := containsSubstr result.stderr "etcdserver: request timed out"
                    || containsSubstr result.stderr "request timed out"
                    || containsSubstr result.stderr "connection refused"
    if isTransient then
      IO.eprintln s!"# kubectl apply hit transient error, retrying in 5s..."
      IO.sleep 5000
    else
      -- Non-transient: fail immediately
      IO.eprintln s!"# kubectl apply FAILED (exit {result.exitCode})"
      IO.eprintln s!"# stdout: {result.stdout}"
      IO.eprintln s!"# stderr: {result.stderr}"
      let lines := yaml.splitOn "\n"
      let head := lines.take 20
      IO.eprintln s!"# --- first {head.length}/{lines.length} lines of rejected YAML ---"
      for l in head do IO.eprintln s!"#  | {l}"
      throw (IO.userError s!"kubectl apply failed (exit {result.exitCode}): {result.stderr}")
  -- All retries exhausted
  throw (IO.userError s!"kubectl apply failed after {maxRetries} retries: {lastErr}")

/-- Dump operator logs for debugging failures. -/
def dumpOperatorLogs (cfg : ClusterConfig) : IO Unit := do
  IO.eprintln s!"# --- Operator logs ({cfg.operatorName}) ---"
  let logs ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 30
  for line in logs.splitOn "\n" do
    IO.eprintln s!"#   {line}"

/-- Deploy a full cluster: namespace → CRD/RBAC → FlareCluster CR → partition services →
    debug pod → empty ConfigMap → operator → StatefulSet -/
def deployCluster (cfg : ClusterConfig) : IO Unit := do
  IO.eprintln s!"# Deploying cluster '{cfg.name}' in namespace '{cfg.«namespace»}'"

  -- Ensure namespace. If a stuck Terminating namespace from a prior run is
  -- still present, wait up to 30s for it to finish so that subsequent
  -- resource creates don't fail with "namespace is being terminated".
  let _ ← waitForCondition s!"namespace {cfg.«namespace»} not Terminating" 30 do
    match ← kubectl ["get", "namespace", cfg.«namespace», "-o", "jsonpath={.status.phase}"] with
    | .ok phase => return (phase.trim != "Terminating")
    | .error _ => return true  -- NotFound → can create fresh
  let _ ← kubectl ["create", "namespace", cfg.«namespace»]

  -- Wait for the `default` ServiceAccount to be created by the k8s SA
  -- controller.  On a fresh kind cluster, the SA controller lags behind
  -- namespace creation — typically by a few seconds, but up to ~60s when
  -- the apiserver is under load or just restarted.  Without this wait,
  -- the debug pod and operator pod both fail to start with
  -- "serviceaccount 'default' not found".
  let _ ← waitForCondition s!"default ServiceAccount in {cfg.«namespace»}" 120 do
    match ← kubectl ["get", "serviceaccount", "default", "-n", cfg.«namespace»,
                     "-o", "jsonpath={.metadata.name}"] with
    | .ok name => return (name.trim == "default")
    | .error _ => return false

  -- The CRD and the cluster-scoped ClusterRole `flare-operator` are
  -- installed ONCE from the helm chart (the CI "Deploy operator (helm
  -- chart)" step; for a local run, `helm template helm/flare-operator
  -- --set fullnameOverride=flare-operator --include-crds | kubectl apply`).
  -- The chart is the single source of truth — no deploy/*.yaml copy to
  -- drift (the readiness-probe and nodes-RBAC bugs were both such drift).
  -- Verify both exist (retry: on a fresh kind cluster the helm apply and
  -- this binary can race the apiserver's CRD discovery cache).
  let crdReady ← waitForCondition "FlareCluster CRD established" 60 do
    match ← kubectl ["get", "crd", "flareclusters.flare.gree.net",
        "-o", "jsonpath={.status.conditions[?(@.type==\"Established\")].status}"] with
    | .ok s => return s.trim == "True"
    | .error _ => return false
  if !crdReady then
    throw (IO.userError "FlareCluster CRD not established — is the chart installed? \
      (helm template helm/flare-operator --set fullnameOverride=flare-operator --include-crds | kubectl apply -f -)")
  let roleReady ← waitForCondition "ClusterRole flare-operator present" 60 do
    match ← kubectl ["get", "clusterrole", "flare-operator", "-o", "jsonpath={.metadata.name}"] with
    | .ok name => return name.trim == "flare-operator"
    | .error _ => return false
  if !roleReady then
    throw (IO.userError "ClusterRole flare-operator missing — install the helm chart first (see above)")

  -- Create ServiceAccount and ClusterRoleBinding in test namespace
  -- (not using deploy/rbac.yaml which is hardcoded for flare-system namespace)
  applyYaml (serviceAccountYaml cfg)
  applyYaml (clusterRoleBindingYaml cfg)

  -- Create FlareCluster CR
  applyYaml (flareClusterCrdYaml cfg)

  -- Create partition services
  for i in List.range cfg.partitions do
    applyYaml (partitionServiceYaml cfg i)

  -- Create empty ConfigMap for replication config.
  -- This ConfigMap MUST exist before StatefulSet is deployed, because the
  -- flared pods mount it at /etc/flared/extra.conf and flared's
  -- `ini_option::load()` exits immediately if `--config` points at a missing
  -- file.  Using direct kubectl (not `sh -c`) so failures are visible.
  let cmName := s!"{cfg.name}-config"
  match ← kubectl ["create", "configmap", cmName, "-n", cfg.«namespace»,
                    s!"--from-literal=extra.conf={cfg.extraFlaredConf}"] with
  | .ok _ => pure ()
  | .error e =>
    -- "AlreadyExists" is fine; anything else is a real failure we want to see.
    if containsSubstr e "AlreadyExists" then pure ()
    else
      IO.eprintln s!"# ERROR: could not create {cmName}: {e}"
      throw (IO.userError s!"configmap create failed: {e}")
  -- Verify the ConfigMap is actually there (catches the "namespace was
  -- Terminating and swallowed the create" race).
  match ← kubectlGetJsonpath "configmap" cmName cfg.«namespace» "{.metadata.name}" with
  | .ok name =>
    if name.trim == cmName then pure ()
    else
      IO.eprintln s!"# ERROR: ConfigMap {cmName} missing after create (got '{name}')"
      throw (IO.userError s!"ConfigMap {cmName} vanished after create")
  | .error e =>
    IO.eprintln s!"# ERROR: ConfigMap {cmName} not readable after create: {e}"
    throw (IO.userError s!"ConfigMap {cmName} missing after create")

  -- Create debug pod (direct kubectl so errors are visible)
  match ← kubectl ["run", cfg.debugPod, s!"--namespace={cfg.«namespace»}",
                    "--image=busybox:1.36", "--restart=Never", "--command", "--",
                    "sleep", "3600"] with
  | .ok _ => pure ()
  | .error e =>
    if containsSubstr e "AlreadyExists" then pure ()
    else
      IO.eprintln s!"# WARNING: could not create debug pod {cfg.debugPod}: {e}"
  let _ ← kubectlWaitReady s!"pod/{cfg.debugPod}" cfg.«namespace» 60

  -- Deploy operator
  applyYaml (operatorDeploymentYaml cfg)

  -- Wait for operator to be ready.
  -- 300s accounts for image pull on a fresh node (flare-operator image is
  -- ~300 MB) plus the operator's own startup (lease acquisition + initial
  -- CRD fetch retries).
  IO.eprintln s!"# Waiting for operator deployment to be ready..."
  let operatorReady ← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" cfg.«namespace» 300
  if !operatorReady then
    IO.eprintln s!"# ERROR: Operator deployment failed to become ready"
    dumpOperatorLogs cfg
    let _ ← kubectl ["get", "pods", "-n", cfg.«namespace»]
    let _ ← kubectl ["describe", "deployment", cfg.operatorName, "-n", cfg.«namespace»]
    throw (IO.userError "Operator deployment failed")

  IO.eprintln s!"# Operator ready, waiting 10s for first reconcile cycle..."
  IO.sleep 10000

  -- Verify ConfigMap is STILL there before deploying StatefulSet.  Flared
  -- pods mount {cfg.name}-config/extra.conf at startup; if the ConfigMap
  -- is missing, flared crashes with "/etc/flared/extra.conf not found"
  -- and the pod goes into CrashLoopBackOff.
  let cmName := s!"{cfg.name}-config"
  match ← kubectlGetJsonpath "configmap" cmName cfg.«namespace» "{.metadata.name}" with
  | .ok name =>
    if name.trim == cmName then
      IO.eprintln s!"# ConfigMap {cmName} confirmed present before StatefulSet deploy"
    else
      IO.eprintln s!"# ERROR: ConfigMap {cmName} missing before StatefulSet deploy (got '{name}')"
      throw (IO.userError s!"ConfigMap {cmName} vanished before StatefulSet deploy")
  | .error e =>
    IO.eprintln s!"# ERROR: ConfigMap {cmName} not found before StatefulSet deploy: {e}"
    throw (IO.userError s!"ConfigMap {cmName} not found: {e}")

  -- Deploy StatefulSet
  IO.eprintln s!"# Deploying StatefulSet..."
  applyYaml (statefulSetYaml cfg)

/-- Deploy a second cluster for inter-cluster replication tests. -/
def deploySecondCluster (cfg : ClusterConfig) : IO Unit := do
  IO.eprintln s!"# Deploying second cluster '{cfg.name}'"

  -- Ensure namespace exists
  let _ ← kubectl ["create", "namespace", cfg.«namespace»]

  -- Create ServiceAccount and ClusterRoleBinding in second cluster's namespace
  applyYaml (serviceAccountYaml cfg)
  applyYaml (clusterRoleBindingYaml cfg)

  -- Create FlareCluster CR
  applyYaml (flareClusterCrdYaml cfg)

  -- Create partition services
  for i in List.range cfg.partitions do
    applyYaml (partitionServiceYaml cfg i)

  -- Create empty ConfigMap for replication config
  let cmName := s!"{cfg.name}-config"
  try
    let result ← IO.Process.output {
      cmd := "sh"
      args := #["-c", s!"kubectl create configmap {cmName} -n {cfg.«namespace»} --from-literal='extra.conf=' 2>/dev/null || true"]
    }
    let _ := result
    pure ()
  catch _ => pure ()

  -- Create debug pod
  try
    let result ← IO.Process.output {
      cmd := "sh"
      args := #["-c", s!"kubectl run {cfg.debugPod} --namespace={cfg.«namespace»} --image=busybox:1.36 --restart=Never --command -- sleep 3600 2>/dev/null || true"]
    }
    let _ := result
    pure ()
  catch _ => pure ()
  let _ ← kubectlWaitReady s!"pod/{cfg.debugPod}" cfg.«namespace» 60

  -- Deploy operator
  applyYaml (operatorDeploymentYaml cfg)
  let _ ← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" cfg.«namespace» 300

  IO.sleep 10000

  -- Deploy StatefulSet
  applyYaml (statefulSetYaml cfg)

/-- Cleanup all resources for a cluster. -/
def cleanupCluster (cfg : ClusterConfig) : IO Unit := do
  IO.eprintln s!"# Cleaning up cluster '{cfg.name}'"
  let ns := cfg.«namespace»
  kubectlDelete "flarecluster" cfg.name ns
  kubectlDelete "statefulset" s!"{cfg.name}-nodes" ns
  kubectlDelete "deployment" cfg.operatorName ns
  kubectlDelete "service" s!"{cfg.name}-nodes" ns
  kubectlDelete "service" cfg.operatorName ns
  kubectlDelete "configmap" s!"{cfg.name}-config" ns
  kubectlDelete "configmap" s!"{cfg.name}-node-map" ns
  kubectlDelete "lease" s!"{cfg.name}-operator-lease" ns
  for i in List.range cfg.partitions do
    kubectlDelete "service" s!"{cfg.name}-{i}" ns
  -- volumeClaimTemplates PVCs outlive the StatefulSet by design; delete them
  -- explicitly so a re-run starts from empty storage.
  if cfg.usePvc then
    for i in List.range (cfg.partitions * cfg.replicas) do
      kubectlDelete "pvc" s!"data-{cfg.name}-nodes-{i}" ns
  -- Delete ClusterRoleBinding (cluster-scoped resource)
  let bindingName := s!"flare-operator-{ns}"
  let _ ← kubectl ["delete", "clusterrolebinding", bindingName, "--ignore-not-found"]
  -- Delete debug pod
  let _ ← kubectl ["delete", "pod", cfg.debugPod, "-n", ns,
                    "--force", "--grace-period=0", "--ignore-not-found"]
  IO.sleep 3000

/-- Wait for cluster to be stable (all pods ready + node registration + grace period). -/
def waitForStable (cfg : ClusterConfig) (graceSec : Nat := 50) : IO Bool := do
  let numPods := cfg.partitions * cfg.replicas

  -- Wait for StatefulSet rollout
  IO.eprintln s!"# Waiting for StatefulSet {cfg.name}-nodes to be ready..."
  let rolloutOk ← kubectlRolloutStatus s!"statefulset/{cfg.name}-nodes" cfg.«namespace» 300
  if !rolloutOk then
    IO.eprintln s!"# ERROR: StatefulSet rollout failed"
    IO.eprintln s!"# Dumping debug info..."
    let _ ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"cluster={cfg.name}"]
    let _ ← kubectl ["describe", "statefulset", s!"{cfg.name}-nodes", "-n", cfg.«namespace»]
    let _ ← kubectl ["get", "events", "-n", cfg.«namespace», "--sort-by=.lastTimestamp"]
    dumpOperatorLogs cfg
    return false

  -- Wait for all pods to be ready
  let podsReady ← waitForCondition s!"all {numPods} pods ready" 180 do
    match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
              "{.status.readyReplicas}" with
    | .ok val => return (val.toNat?.getD 0 >= numPods)
    | .error _ => return false
  if !podsReady then return false

  -- Wait for nodes to register with operator.
  -- 300s timeout: RocksDB-backed nodes with large datasets can take 30-60s to
  -- open the database and send the initial `node add`.  The previous 120s was
  -- too tight for production-sized data (100 GB+) and caused false negatives
  -- in E2E tests on loaded machines.
  let nodesRegistered ← waitForCondition s!"{numPods} nodes registered" 300 do
    let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
    let entries := parseNodeSync sync
    return (entries.length >= numPods)
  if !nodesRegistered then return false

  -- Grace period for startup and initial reconciliation
  IO.eprintln s!"# Waiting {graceSec}s grace period for operator reconciliation..."
  IO.sleep (graceSec * 1000).toUInt32

  -- Verify operator is reconciling by checking recent logs
  IO.eprintln s!"# Checking operator activity..."
  dumpOperatorLogs cfg

  return true

end FlareOperator.E2E.Setup
