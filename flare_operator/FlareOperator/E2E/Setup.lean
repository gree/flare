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
  /-- Extra environment for the per-suite operator, as (name, value). Used
      by suites that need a test seam the production default leaves off. -/
  operatorEnv : List (String × String) := []
  /-- Extra environment for every flared container (test seams such as
      FLARE_TEST_DISABLE_SNAPSHOT_BOOTSTRAP), as (name, value). -/
  flaredEnv : List (String × String) := []
  /-- Extra flared command-line options (e.g. "--reconstruction-bwlimit 128"
      to make a dump last long enough to interrupt). -/
  flaredArgs : String := ""
  /-- Persist flared data on a PVC (volumeClaimTemplates) instead of the
      pod-local tmpdir. With a PVC the data directory survives pod
      recreation, so a partition can recover its data even when the master
      AND all its slaves die at once — the case replica promotion alone can
      never cover. Mirrors the production example
      helm/flare-operator/examples/flare-cluster-persistent.yaml. -/
  usePvc : Bool := false
  /-- Keep flared data on tmpfs: a memory-backed emptyDir (medium: Memory)
      mounted where the PVC would be. Mirrors a production tmpfs cluster:
      the data counts against the pod's memory, survives a container
      restart inside the pod, and is gone when the pod is deleted.
      Mutually exclusive with usePvc. -/
  useTmpfs : Bool := false
  tmpfsSize : String := "2Gi"
  /-- flared container memory limit / request. The default fits the small
      E2E datasets; the scale evaluation raises it (RocksDB's block cache
      plus a 64 MB write buffer OOM-killed a 512Mi master under a 2M-key
      load). -/
  flaredMemoryLimit : String := "512Mi"
  /-- flared container CPU limit. 500m on CI; evaluations raise it to tell
      CPU throttling apart from protocol limits. -/
  flaredCpuLimit : String := "500m"
  flaredMemoryRequest : String := "256Mi"
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
  /-- Put `spec.rocksdb.readUnavailableError: true` in the FlareCluster (the
      production read policy, R2): the operator renders it into extra.conf
      and keeps it there; a line in `extraFlaredConf` would be overwritten
      by the operator's own extra.conf. Part of the CR, so a CR recreated
      mid-suite keeps it. -/
  readUnavailableError : Bool := false
  /-- Copy retention (§9): `rocksdb-rebuild-reserve-bytes` for the suite's
      flared. Unset stops every staged rebuild, so suites set it: baked into
      the initial extra.conf (pods boot with it) and, when the CR carries a
      rocksdb block (the operator then owns extra.conf), into the CR too.
      `none` = leave it unset (the reserve_unset test). -/
  rebuildReserveBytes : Option Nat := some e2eRebuildReserveBytes
  /-- Also put the reserve in the FlareCluster CR (the operator then owns
      extra.conf, so suite lines in `extraFlaredConf` would be dropped at
      its first rewrite). Needed where the CR is the source of truth for a
      cluster the OPERATOR provisions (a blue/green migration target copies
      the source CR's spec.rocksdb). -/
  reserveInCr : Bool := false
  /-- preStop drain window (seconds). >0 adds a `sleep {drainSeconds}` preStop
      hook so flared stays alive+Ready while Terminating — the window the
      operator's graceful drain (demote leaving master to a live proxy, promote
      a replacement) needs to be observable. 0 = no hook (fast pod deletes, the
      default for most suites). Mirrors the chart's cluster.drainSeconds. -/
  drainSeconds : Nat := 0
  /-- Deploy the operator WITHOUT its FlareCluster and StatefulSet (they come
      later through `deployDeferredCluster`): the operator-before-cluster
      install the SAF-09 waiting state exists for. -/
  deferClusterCr : Bool := false
  /-- Run a RELEASED flared / operator image instead of the locally built
      `:test` one (pulled, IfNotPresent). The upgrade suite starts on the
      deployed release and rolls to the build under test. -/
  flaredImageOverride : Option String := none
  operatorImageOverride : Option String := none
  /-- A shared, real cluster (the reserve measurement, decision 2026-10-08):
      bind the operator's ServiceAccount with a namespaced RoleBinding to this
      EXISTING ClusterRole instead of a ClusterRoleBinding to `flare-operator`;
      nothing cluster-scoped is created, checked for or deleted. -/
  roleBindingTo : Option String := none
  /-- Pin every pod of the suite (operator, flared, debug) to this node
      (`kubernetes.io/hostname`). -/
  nodeHost : Option String := none
  /-- When no existing node is named: keep every pod off these nodes (e.g.
      the nodes holding another cluster's data pods) and inside this node
      pool (`label=value`); the flared pods are co-located (required pod
      affinity), so at most ONE added node can satisfy them. -/
  avoidNodes : List String := []
  nodePool : Option String := none
  /-- A ResourceQuota `hard:` block (YAML lines, 4-space indent) for the
      namespace, plus a LimitRange so pods without explicit resources get
      requests = limits from `limitDefaults` (cpu, memory). -/
  quotaHard : Option String := none
  limitDefaults : String × String := ("500m", "256Mi")
  flaredCpuRequest : String := "100m"
  debugImage : String := "busybox:1.36"
  deriving Repr

/-- Image tag used for the flared container in this cluster. -/
def ClusterConfig.flaredImage (cfg : ClusterConfig) : String :=
  match cfg.flaredImageOverride with
  | some i => i
  | none =>
    match cfg.storageBackend with
    | "rocksdb" => "flare-node-rocksdb:test"
    | _ => "flare-node:test"

/-- `Never` for the locally loaded `:test` images, `IfNotPresent` for a
    released image that kind must pull. -/
def pullPolicyFor (override : Option String) : String :=
  if override.isSome then "IfNotPresent" else "Never"

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

/-- `nodeSelector` pinning a pod spec to `cfg.nodeHost` (empty when unset). -/
def nodeSelectorBlock (cfg : ClusterConfig) (indent : Nat) : String :=
  match cfg.nodeHost with
  | none => ""
  | some h =>
    let pad := String.mk (List.replicate indent ' ')
    s!"\n{pad}nodeSelector:\n{pad}  kubernetes.io/hostname: \"{h}\""

/-- Required node affinity (pool In, hostname NotIn avoidNodes) and, for the
    flared pods, required co-location with each other. Empty when unset. -/
def placementBlock (cfg : ClusterConfig) (indent : Nat) (colocateLabel : Option String) : String :=
  if cfg.nodeHost.isSome || (cfg.avoidNodes.isEmpty && cfg.nodePool.isNone) then "" else
  let pad := String.mk (List.replicate indent ' ')
  let pool := match cfg.nodePool.map (·.splitOn "=") with
    | some [k, v] => s!"\n{pad}            - key: {k}\n{pad}              operator: In\n{pad}              values: [\"{v}\"]"
    | _ => ""
  let avoid := if cfg.avoidNodes.isEmpty then "" else
    s!"\n{pad}            - key: kubernetes.io/hostname\n{pad}              operator: NotIn\n{pad}              values: [{String.intercalate ", " (cfg.avoidNodes.map fun n => s!"\"{n}\"")}]"
  let coloc := match colocateLabel with
    | some sel => s!"\n{pad}  podAffinity:\n{pad}    requiredDuringSchedulingIgnoredDuringExecution:\n{pad}      - labelSelector:\n{pad}          matchLabels:\n{pad}            cluster: {sel}\n{pad}        topologyKey: kubernetes.io/hostname"
    | none => ""
  s!"\n{pad}affinity:\n{pad}  nodeAffinity:\n{pad}    requiredDuringSchedulingIgnoredDuringExecution:\n{pad}      nodeSelectorTerms:\n{pad}        - matchExpressions:{pool}{avoid}{coloc}"

/-- Namespaced RoleBinding to an existing ClusterRole (no cluster-scoped object). -/
def roleBindingYaml (cfg : ClusterConfig) (clusterRole : String) : String :=
  s!"apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: flare-operator
  namespace: {cfg.«namespace»}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {clusterRole}
subjects:
  - kind: ServiceAccount
    name: flare-operator
    namespace: {cfg.«namespace»}"

def quotaYaml (cfg : ClusterConfig) (hard : String) : String :=
  s!"apiVersion: v1
kind: ResourceQuota
metadata:
  name: measure-caps
  namespace: {cfg.«namespace»}
spec:
  hard:
{hard}
---
apiVersion: v1
kind: LimitRange
metadata:
  name: measure-defaults
  namespace: {cfg.«namespace»}
spec:
  limits:
    - type: Container
      default:
        cpu: {cfg.limitDefaults.1}
        memory: {cfg.limitDefaults.2}
      defaultRequest:
        cpu: {cfg.limitDefaults.1}
        memory: {cfg.limitDefaults.2}"

/-- Generate operator Deployment + Service YAML.

    The memory LIMIT is a ceiling, not a reservation: 256Mi is enough for
    the Lean runtime on the amd64 CI runners but OOMKills it on arm64
    (Docker Desktop), where every suite then fails during setup with
    "cluster did not stabilize" and no visible cause — the operator pod is
    already gone by the time a test looks. 768Mi was still marginal: a
    restarted operator did not come back within a 240s recovery window,
    while the same binary under 1Gi did. There is no architecture condition
    here, so the higher ceiling applies on the amd64 runners too; a ceiling
    that is not reached costs nothing. -/
def operatorDeploymentYaml (cfg : ClusterConfig) : String :=
  let envBlock :=
    if cfg.operatorEnv.isEmpty then ""
    else "\n          env:" ++ String.join (cfg.operatorEnv.map (fun (k, v) =>
      s!"\n            - name: {k}\n              value: \"{v}\""))
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
      serviceAccountName: flare-operator{nodeSelectorBlock cfg 6}{placementBlock cfg 6 none}
      containers:
        - name: flare-operator
          image: {cfg.operatorImageOverride.getD "flare-operator:test"}
          imagePullPolicy: {pullPolicyFor cfg.operatorImageOverride}
          args:
            - \"--namespace\"
            - \"{ns}\"
            - \"--cluster-name\"
            - \"{cfg.name}\"
          ports:
            - containerPort: {cfg.operatorPort}
              name: flare-index
              protocol: TCP{envBlock}
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              # ceiling, not a reservation - see operatorDeploymentYaml
              memory: 1Gi
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
  let flaredEnvLines := String.join (cfg.flaredEnv.map fun (k, v) =>
    s!"\n            - name: {k}\n              value: \"{v}\"")
  let persistent := cfg.usePvc || cfg.useTmpfs
  let dataDir := if persistent then "/data/flare" else "/tmp/flare"
  -- RESTORE hook (PVC only): if the marker file exists it names a checkpoint
  -- directory (created by the flared `backup` op, a complete RocksDB dir);
  -- replace the live DB with it and consume the marker, then start flared.
  -- Restore procedure: write the marker on each pod's PVC, delete the pods.
  let prep := if persistent then
      s!"if [ -f {dataDir}/RESTORE ]; then flare-restore-hook {dataDir} || exit 1; fi; mkdir -p {dataDir}; rm -f {dataDir}/flared.pid"
    else
      s!"rm -rf {dataDir}/*.hdb {dataDir}/*.hdb.wal {dataDir}/rocksdb && mkdir -p {dataDir} && rm -f {dataDir}/flared.pid"
  let storageFlag := s!"--storage-type={cfg.storageBackend}"
  -- preStop drain window: keep flared alive+Ready while Terminating so the
  -- operator's graceful drain is observable. grace must exceed drainSeconds.
  let graceSeconds := if cfg.drainSeconds > 0 then cfg.drainSeconds + 10 else 5
  let preStopBlock := if cfg.drainSeconds > 0 then
      s!"
          lifecycle:
            preStop:
              exec:
                command: [\"sh\", \"-c\", \"sleep {cfg.drainSeconds}\"]"
    else ""
  let pvcMount := if persistent then "
            - name: data
              mountPath: /data" else ""
  let tmpfsVolume := if cfg.useTmpfs && !cfg.usePvc then s!"
        - name: data
          emptyDir:
            medium: Memory
            sizeLimit: {cfg.tmpfsSize}" else ""
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
  # REQUIRED with the sync-gated readiness probe (mirrors the helm chart): a
  # re-seeding slave is NotReady for the whole reconstruction, but the master
  # pushes the dump to the slave's per-pod DNS name (its node_key). Without
  # this a NotReady pod has no DNS record -> it can never finish seeding.
  publishNotReadyAddresses: true
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
  # podManagementPolicy stays OrderedReady (the default; same as the helm
  # chart). Parallel was tried for faster bootstrap under the sync-gated
  # readiness probe and REGRESSED the suite: it also parallelizes TERMINATION,
  # so a scale-in could kill a partition's master and slave simultaneously
  # (readiness gates updates, not deletions), and simultaneous re-registration
  # after a total-partition kill broke master re-establishment. Sequential
  # bootstrap on Ready=Active is slower but is the operator's proven path.
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
      terminationGracePeriodSeconds: {graceSeconds}{nodeSelectorBlock cfg 6}{placementBlock cfg 6 (some cluster)}
      containers:
        - name: flared
          image: {image}
          imagePullPolicy: {pullPolicyFor cfg.flaredImageOverride}
          command: [\"sh\", \"-c\", \"{prep} && exec flared --config=/etc/flared/extra.conf --data-dir {dataDir} --server-port {cfg.flarePort} --index-server-name {operatorSvc} --index-server-port {cfg.operatorPort} {storageFlag} --metrics-server-port 9150 --stderr {cfg.flaredArgs}\"]{preStopBlock}
          # Same allocator setting as the chart (cluster.mallocArenaMax,
          # default 2). Without it glibc keeps up to 8 arenas per core and the
          # test pods fragment memory in a way production pods do not.
          env:
            - name: MALLOC_ARENA_MAX
              value: \"2\"{flaredEnvLines}
          ports:
            - containerPort: {cfg.flarePort}
              name: flare
            - containerPort: 9150
              name: metrics
          volumeMounts:
            - name: flared-config
              mountPath: /etc/flared{pvcMount}
          livenessProbe:
            tcpSocket:
              port: {cfg.flarePort}
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          # Sync-gated readiness (mirrors the helm chart): Ready only when this
          # node is state=active in the node map flared holds — i.e. the operator
          # judged it fully synced. Makes STS rolling updates wait for a real
          # full copy before killing the next pod.
          readinessProbe:
            exec:
              command:
                - /bin/bash
                - -c
                - |
                  exec 3<>/dev/tcp/127.0.0.1/{cfg.flarePort} || exit 1
                  printf 'stats nodes\\r\\nquit\\r\\n' >&3
                  out=$(tr -d '\\r' <&3)
                  me=\"$(hostname -f):{cfg.flarePort}\"
                  case \"$out\" in *\"STAT $me:state active\"*) exit 0;; esac
                  # Limbo clause (mirrors the helm chart): a syncing member of a
                  # partition with NO active master has nothing to sync from —
                  # total-partition recovery. Report Ready so the OrderedReady
                  # StatefulSet can recreate the peer that will become master.
                  mypart=$(printf '%s\\n' \"$out\" | sed -n \"s/^STAT $me:partition //p\")
                  [ -n \"$mypart\" ] || exit 1
                  [ \"$mypart\" != \"-1\" ] || exit 1
                  for key in $(printf '%s\\n' \"$out\" | sed -n \"s/^STAT \\(.*\\):partition $mypart$/\\1/p\"); do
                    printf '%s\\n' \"$out\" | grep -q \"^STAT $key:role master$\" || continue
                    printf '%s\\n' \"$out\" | grep -q \"^STAT $key:state active$\" && exit 1
                  done
                  exit 0
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 4
            failureThreshold: 3
          resources:
            requests:
              cpu: {cfg.flaredCpuRequest}
              memory: {cfg.flaredMemoryRequest}
            limits:
              cpu: {cfg.flaredCpuLimit}
              memory: {cfg.flaredMemoryLimit}
      volumes:
        - name: flared-config
          configMap:
            name: {cluster}-config{tmpfsVolume}{pvcTemplates}"

/-- The extra.conf pods boot with: the suite's lines plus the rebuild reserve. -/
def bootFlaredConf (cfg : ClusterConfig) : String :=
  match cfg.rebuildReserveBytes with
  | some n =>
    let line := s!"rocksdb-rebuild-reserve-bytes = {n}"
    if cfg.extraFlaredConf.isEmpty then line else cfg.extraFlaredConf ++ "\n" ++ line
  | none => cfg.extraFlaredConf

/-- Generate FlareCluster CRD YAML. -/
def flareClusterCrdYaml (cfg : ClusterConfig) : String :=
  s!"apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: {cfg.name}
  namespace: {cfg.«namespace»}
spec:
  partitions: {cfg.partitions}
  replicas: {cfg.replicas}" ++
  (if cfg.readUnavailableError || cfg.reserveInCr then
    "\n  rocksdb:" ++ (if cfg.readUnavailableError then "\n    readUnavailableError: true" else "") ++
      (match cfg.rebuildReserveBytes with
       | some n => s!"\n    rebuildReserveBytes: {n}"
       | none => "")
   else "")

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

/-- SAF-09: approve the first build of this (new) FlareCluster, bound to
    its own UID — what a person does once at a real first install. Without
    it a fresh cluster's operator cannot tell a first build from a loss
    (flared does not answer before the operator serves) and waits. -/
def approveFirstBuild (cfg : ClusterConfig) : IO Unit := do
  for _ in [0:10] do
    let out ← IO.Process.output { cmd := "kubectl", args := #["get", "flarecluster", cfg.name, "-n", cfg.«namespace», "-o", "jsonpath={.metadata.uid}"] }
    let uid := out.stdout.trim
    if out.exitCode == 0 && !uid.isEmpty then
      let r ← IO.Process.output { cmd := "kubectl", args := #["annotate", "flarecluster", cfg.name, "-n", cfg.«namespace», "--overwrite", s!"flare.gree.net/first-build-approved={uid}"] }
      if r.exitCode == 0 then return
    IO.sleep 2000
  IO.eprintln s!"# WARNING: could not approve the first build of {cfg.name}"

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
  if let some hard := cfg.quotaHard then applyYaml (quotaYaml cfg hard)
  let roleReady ← if cfg.roleBindingTo.isSome then pure true else waitForCondition "ClusterRole flare-operator present" 60 do
    match ← kubectl ["get", "clusterrole", "flare-operator", "-o", "jsonpath={.metadata.name}"] with
    | .ok name => return name.trim == "flare-operator"
    | .error _ => return false
  if !roleReady then
    throw (IO.userError "ClusterRole flare-operator missing — install the helm chart first (see above)")

  -- Create ServiceAccount and ClusterRoleBinding in test namespace
  -- (not using deploy/rbac.yaml which is hardcoded for flare-system namespace)
  applyYaml (serviceAccountYaml cfg)
  match cfg.roleBindingTo with
  | some role => applyYaml (roleBindingYaml cfg role)
  | none => applyYaml (clusterRoleBindingYaml cfg)

  -- Create FlareCluster CR (unless the test adds it later)
  if !cfg.deferClusterCr then
    applyYaml (flareClusterCrdYaml cfg)
    approveFirstBuild cfg

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
                    s!"--from-literal=extra.conf={bootFlaredConf cfg}"] with
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
  let overrides := match cfg.nodeHost with
    | some h => [s!"--overrides=\{\"spec\":\{\"nodeSelector\":\{\"kubernetes.io/hostname\":\"{h}\"}}}"]
    | none =>
      if cfg.avoidNodes.isEmpty then [] else
      let vals := String.intercalate "," (cfg.avoidNodes.map fun n => s!"\"{n}\"")
      [s!"--overrides=\{\"spec\":\{\"affinity\":\{\"nodeAffinity\":\{\"requiredDuringSchedulingIgnoredDuringExecution\":\{\"nodeSelectorTerms\":[\{\"matchExpressions\":[\{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[{vals}]}]}]}}}}}"]
  match ← kubectl (["run", cfg.debugPod, s!"--namespace={cfg.«namespace»}",
                    s!"--image={cfg.debugImage}", "--restart=Never"] ++ overrides ++ ["--command", "--",
                    -- 1 day, not 1 h: the scale evaluation's load ran past an
                    -- hour and every chunk after 3573 s failed with
                    -- "container not found" (manual run 36899086870).
                    "sleep", "86400"]) with
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
  if cfg.deferClusterCr then
    IO.eprintln "# FlareCluster and StatefulSet deferred (deployDeferredCluster)"
  else
    IO.eprintln s!"# Deploying StatefulSet..."
    applyYaml (statefulSetYaml cfg)

/-- Create the FlareCluster (optionally approving its first build) and the
    StatefulSet of a cluster deployed with `deferClusterCr`. -/
def deployDeferredCluster (cfg : ClusterConfig) (approve : Bool := true) : IO Unit := do
  applyYaml (flareClusterCrdYaml cfg)
  if approve then approveFirstBuild cfg
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
  approveFirstBuild cfg

  -- Create partition services
  for i in List.range cfg.partitions do
    applyYaml (partitionServiceYaml cfg i)

  -- Create empty ConfigMap for replication config
  let cmName := s!"{cfg.name}-config"
  try
    let result ← IO.Process.output {
      cmd := "sh"
      -- the boot conf (with the rebuild reserve: unset, every staged
      -- rebuild stops — CI 37578618876 repl-v2 stuck in Prepare)
      args := #["-c", s!"kubectl create configmap {cmName} -n {cfg.«namespace»} --from-literal='extra.conf={bootFlaredConf cfg}' 2>/dev/null || true"]
    }
    let _ := result
    pure ()
  catch _ => pure ()

  -- Create debug pod
  try
    let result ← IO.Process.output {
      cmd := "sh"
      args := #["-c", s!"kubectl run {cfg.debugPod} --namespace={cfg.«namespace»} --image=busybox:1.36 --restart=Never --command -- sleep 86400 2>/dev/null || true"]
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
  kubectlDelete "configmap" s!"{cfg.name}-history" ns
  kubectlDelete "lease" s!"{cfg.name}-operator-lease" ns
  for i in List.range cfg.partitions do
    kubectlDelete "service" s!"{cfg.name}-{i}" ns
  -- volumeClaimTemplates PVCs outlive the StatefulSet by design; delete them
  -- explicitly so a re-run starts from empty storage.
  if cfg.usePvc then
    for i in List.range (cfg.partitions * cfg.replicas) do
      kubectlDelete "pvc" s!"data-{cfg.name}-nodes-{i}" ns
  -- Delete ClusterRoleBinding (cluster-scoped resource)
  if cfg.roleBindingTo.isNone then
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
