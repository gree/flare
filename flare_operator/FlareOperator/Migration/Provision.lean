/-
  Migration/Provision.lean — render the TARGET cluster's resources.

  The target lives in the SAME namespace as the source, on purpose: the
  client-facing external Service cannot select pods across namespaces, so
  same-namespace blue/green makes cutover an atomic selector flip that keeps
  the load balancer (and its IP) as-is.

  What gets created (all labelled `flare.gree.net/migration: <mig name>` so
  abort can delete them wholesale):
    * FlareCluster CR  <target>            (rocksdb spec copied from source)
    * ConfigMap        <target>-config     (extra.conf; must exist before pods)
    * headless Service <target>-nodes      (publishNotReadyAddresses)
    * StatefulSet      <target>-nodes      (image/SA inherited from the live source)
    * Deployment       <target>-operator   (this operator's own image,
                                            --cluster-name <target>)
    * Service          <target>-operator   (index port for the target's flared)

  The YAML mirrors the helm chart's production shape (sync-gated readiness
  with the limbo clause, preStop drain, pid cleanup, MALLOC_ARENA_MAX,
  native metrics port); values the controller cannot know are read from the
  LIVE source objects (flared image from the source StatefulSet, operator
  image + serviceAccount from the controller's own pod).
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.K8s.Bridge

namespace FlareOperator.Migration.Provision

open FlareOperator.K8s

/-- Render `spec.rocksdb` fields as CR YAML lines (2-space indented under
    `rocksdb:`). Empty string when nothing is set. -/
def rocksdbSpecYaml (r : RocksdbConfigSpec) : String :=
  let fields : List (Option String) := [
    r.walTtlSeconds.map (s!"    walTtlSeconds: {·}"),
    r.walSizeLimitMb.map (s!"    walSizeLimitMb: {·}"),
    r.syncWrites.map (fun b => s!"    syncWrites: {if b then "true" else "false"}"),
    r.resyncFailureThreshold.map (s!"    resyncFailureThreshold: {·}"),
    r.walMaxBatchBytes.map (s!"    walMaxBatchBytes: {·}"),
    r.walSyncBwlimit.map (s!"    walSyncBwlimit: {·}"),
    r.walSyncInterval.map (s!"    walSyncInterval: {·}"),
    r.snapshotBwlimit.map (s!"    snapshotBwlimit: {·}"),
    r.flushAllEnabled.map (fun b => s!"    flushAllEnabled: {if b then "true" else "false"}")
  ]
  let lines := fields.filterMap id
  if lines.isEmpty then "" else "\n  rocksdb:\n" ++ String.intercalate "\n" lines

structure TargetPlan where
  migName : String
  ns : String
  /-- The helm release that owns the SOURCE operator (from its own pod's
      app.kubernetes.io/instance label), or none when not helm-managed
      (E2E). When set, every target resource that the release's chart will
      eventually template (CR, config CM, headless Service, StatefulSet) is
      born with helm adoption metadata, so the post-migration values switch
      adopts them cleanly instead of failing on "invalid ownership
      metadata" — this used to be a hand-run annotate loop. -/
  helmRelease : Option String := none
  targetName : String
  partitions : Nat
  replicas : Nat
  persistenceSize : String
  drainSeconds : Nat
  flaredImage : String        -- read from the live source StatefulSet
  operatorImage : String      -- read from the controller's own pod
  serviceAccount : String     -- read from the controller's own pod
  rocksdb : RocksdbConfigSpec -- copied from the source CR
  flarePort : Nat := 12121
  operatorPort : Nat := 12120

def commonLabels (p : TargetPlan) : String :=
  s!"flare.gree.net/migration: {p.migName}"

/-- Extra metadata lines (labels continued + annotations block) for resources
    the helm chart will adopt after the values switch. Callers splice
    `adoptionLabels` right after `commonLabels` (same indent) and
    `adoptionAnnotations` as a sibling of `labels:`. Empty when the source
    operator is not helm-managed. -/
def adoptionLabels (p : TargetPlan) : String :=
  match p.helmRelease with
  | some _ => "\n    app.kubernetes.io/managed-by: Helm"
  | none => ""

def adoptionAnnotations (p : TargetPlan) : String :=
  match p.helmRelease with
  | some rel => s!"
  annotations:
    meta.helm.sh/release-name: {rel}
    meta.helm.sh/release-namespace: {p.ns}"
  | none => ""

def flareClusterYaml (p : TargetPlan) : String :=
  s!"apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: {p.targetName}
  namespace: {p.ns}
  labels:
    {commonLabels p}{adoptionLabels p}{adoptionAnnotations p}
spec:
  partitions: {p.partitions}
  replicas: {p.replicas}{rocksdbSpecYaml p.rocksdb}"

/-- extra.conf seed: flared refuses to start without the file. Content is
    what the target operator would render anyway (rocksdb passthrough + the
    explicit replication-off line), so the first SIGHUP is a no-op. -/
def configMapYaml (p : TargetPlan) : String :=
  let content := FlareOperator.K8s.Bridge.renderFlaredExtraConf p.rocksdb none
  let indented := String.intercalate "\n    " (content.splitOn "\n")
  s!"apiVersion: v1
kind: ConfigMap
metadata:
  name: {p.targetName}-config
  namespace: {p.ns}
  labels:
    {commonLabels p}{adoptionLabels p}{adoptionAnnotations p}
data:
  extra.conf: |
    {indented}"

def operatorYaml (p : TargetPlan) : String :=
  let name := s!"{p.targetName}-operator"
  s!"apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  namespace: {p.ns}
  labels:
    app: {name}
    {commonLabels p}
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
      serviceAccountName: {p.serviceAccount}
      containers:
        - name: flare-operator
          image: {p.operatorImage}
          imagePullPolicy: IfNotPresent
          args:
            - \"--namespace\"
            - \"{p.ns}\"
            - \"--cluster-name\"
            - \"{p.targetName}\"
          env:
            # Self-retire marker: once a helm-managed successor operator for
            # the same cluster is Ready, this operator deletes its own
            # Deployment+Service so the lease hands over IMMEDIATELY —
            # holding it left the successor pair leaderless (no index
            # Service endpoint) and crashlooped the re-pointed StatefulSet.
            - name: FLARE_MIGRATION_PROVISIONED
              value: \"{p.migName}\"
          ports:
            - containerPort: {p.operatorPort}
              name: flare-index
              protocol: TCP
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: \"1\"
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: {p.ns}
  labels:
    {commonLabels p}
spec:
  selector:
    app: {name}
  ports:
    - port: {p.operatorPort}
      targetPort: flare-index
      protocol: TCP
  type: ClusterIP"

def statefulSetYaml (p : TargetPlan) : String :=
  let cluster := p.targetName
  let numPods := p.partitions * p.replicas
  let operatorSvc := s!"{p.targetName}-operator.{p.ns}.svc.cluster.local"
  let graceSeconds := p.drainSeconds + 30
  s!"apiVersion: v1
kind: Service
metadata:
  name: {cluster}-nodes
  namespace: {p.ns}
  labels:
    app: flare
    cluster: {cluster}
    {commonLabels p}{adoptionLabels p}{adoptionAnnotations p}
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: flare
    cluster: {cluster}
  ports:
    - port: {p.flarePort}
      targetPort: flare
      name: flare
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {cluster}-nodes
  namespace: {p.ns}
  labels:
    {commonLabels p}{adoptionLabels p}{adoptionAnnotations p}
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
      terminationGracePeriodSeconds: {graceSeconds}
      containers:
        - name: flared
          image: {p.flaredImage}
          imagePullPolicy: IfNotPresent
          env:
            - name: MALLOC_ARENA_MAX
              value: \"2\"
          command: [\"sh\", \"-c\", \"if [ -f /data/flare/RESTORE ]; then SRC=$(cat /data/flare/RESTORE) && rm -rf /data/flare/flare.rocksdb && cp -a $SRC /data/flare/flare.rocksdb && rm -f /data/flare/RESTORE; fi; mkdir -p /data/flare; rm -f /data/flare/flared.pid; exec flared --config=/etc/flared/extra.conf --data-dir /data/flare --server-port {p.flarePort} --index-server-name {operatorSvc} --index-server-port {p.operatorPort} --storage-type=rocksdb --metrics-server-port 9150 --stderr\"]
          lifecycle:
            preStop:
              exec:
                command: [\"sh\", \"-c\", \"sleep {p.drainSeconds}\"]
          ports:
            - containerPort: {p.flarePort}
              name: flare
            - containerPort: 9150
              name: metrics
          volumeMounts:
            - name: flared-config
              mountPath: /etc/flared
            - name: data
              mountPath: /data
          livenessProbe:
            tcpSocket:
              port: {p.flarePort}
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          readinessProbe:
            exec:
              command:
                - /bin/bash
                - -c
                - |
                  exec 3<>/dev/tcp/127.0.0.1/{p.flarePort} || exit 1
                  printf 'stats nodes\\r\\nquit\\r\\n' >&3
                  out=$(tr -d '\\r' <&3)
                  me=\"$(hostname -f):{p.flarePort}\"
                  case \"$out\" in *\"STAT $me:state active\"*) exit 0;; esac
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
      volumes:
        - name: flared-config
          configMap:
            name: {cluster}-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [\"ReadWriteOnce\"]
        resources:
          requests:
            storage: {p.persistenceSize}"

/-- Every target manifest, in apply order (config before pods). -/
def allManifests (p : TargetPlan) : List String :=
  [flareClusterYaml p, configMapYaml p, operatorYaml p, statefulSetYaml p]

end FlareOperator.Migration.Provision
