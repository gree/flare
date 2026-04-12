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
    This binds the global flare-operator ClusterRole (created by deploy/rbac.yaml in CI)
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
  -- TCH stores a single `.hdb` file; RocksDB stores a directory. The
  -- cleanup line below wipes whichever is there (plus a leftover WAL)
  -- so a fresh pod always starts with an empty data directory.
  let cleanup := "rm -rf /tmp/flare/*.hdb /tmp/flare/*.hdb.wal /tmp/flare/rocksdb"
  let storageFlag := s!"--storage-type={cfg.storageBackend}"
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
          command: [\"sh\", \"-c\", \"{cleanup} && mkdir -p /tmp/flare && exec flared --config=/etc/flared/extra.conf --data-dir /tmp/flare --server-port {cfg.flarePort} --index-server-name {operatorSvc} --index-server-port {cfg.operatorPort} {storageFlag} --stderr\"]
          ports:
            - containerPort: {cfg.flarePort}
              name: flare
          volumeMounts:
            - name: flared-config
              mountPath: /etc/flared
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
            name: {cluster}-config"

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

/-- Apply YAML string via kubectl.

    On failure, prints the generated YAML (leading 20 lines so the test log
    stays readable) alongside kubectl's stdout and stderr, then re-throws so
    setup fails loudly instead of limping along with a half-applied cluster.
    This replaces an older silent-swallow pattern that was masking apply
    failures behind later "rollout timed out" errors in waitForStable. -/
private def applyYaml (yaml : String) : IO Unit := do
  let result ← try
    IO.Process.output {
      cmd := "sh"
      args := #["-c", s!"cat <<'ENDOFYAML' | kubectl apply -f -\n{yaml}\nENDOFYAML"]
    }
  catch e =>
    IO.eprintln s!"# kubectl apply spawn error: {e}"
    throw (IO.userError s!"kubectl apply spawn error: {e}")
  if result.exitCode != 0 then
    IO.eprintln s!"# kubectl apply FAILED (exit {result.exitCode})"
    IO.eprintln s!"# stdout: {result.stdout}"
    IO.eprintln s!"# stderr: {result.stderr}"
    -- Show the first ~20 lines of the generated YAML to identify what was rejected.
    let lines := yaml.splitOn "\n"
    let head := lines.take 20
    IO.eprintln s!"# --- first {head.length}/{lines.length} lines of rejected YAML ---"
    for l in head do IO.eprintln s!"#  | {l}"
    throw (IO.userError s!"kubectl apply failed (exit {result.exitCode}): {result.stderr}")

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

  -- Ensure namespace
  let _ ← kubectl ["create", "namespace", cfg.«namespace»]

  -- Apply CRD (cluster-scoped, only needs to be done once)
  let _ ← kubectl ["apply", "-f", "deploy/crd.yaml"]

  -- Create ServiceAccount and ClusterRoleBinding in test namespace
  -- (not using deploy/rbac.yaml which is hardcoded for flare-system namespace)
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

  -- Wait for operator to be ready
  IO.eprintln s!"# Waiting for operator deployment to be ready..."
  let operatorReady ← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" cfg.«namespace» 120
  if !operatorReady then
    IO.eprintln s!"# ERROR: Operator deployment failed to become ready"
    dumpOperatorLogs cfg
    let _ ← kubectl ["get", "pods", "-n", cfg.«namespace»]
    let _ ← kubectl ["describe", "deployment", cfg.operatorName, "-n", cfg.«namespace»]
    throw (IO.userError "Operator deployment failed")

  IO.eprintln s!"# Operator ready, waiting 10s for first reconcile cycle..."
  IO.sleep 10000

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
  let _ ← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" cfg.«namespace» 120

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

  -- Wait for nodes to register with operator
  let nodesRegistered ← waitForCondition s!"{numPods} nodes registered" 120 do
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
