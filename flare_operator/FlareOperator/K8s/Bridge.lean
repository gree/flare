/-
  Bridge.lean - High-level K8s kubectl bridge

  Wraps the low-level kubectl subprocess calls from Kubectl.lean into
  typed, operator-specific operations. Each function issues exactly one
  kubectl call and returns a typed result.

  Functions:
  - getFlareClusterCRD: fetch CRD spec as FlareClusterView
  - listFlaredPods: list pods with PodInfo (name, ip, port, ready)
  - patchClientServiceSelector: point a Service at a specific pod
  - deletePod: force-delete a pod by name
  - updateFlaredConfigMap: update a ConfigMap with node-map data
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.K8s.Retry
import FlareOperator.Kubectl

namespace FlareOperator.K8s.Bridge

open FlareOperator.K8s
open FlareOperator.K8s.Retry
open FlareOperator.Kubectl

-- ===========================================================================
-- PodInfo: typed pod metadata returned by listFlaredPods
-- ===========================================================================

/-- Typed pod information returned from K8s API. -/
structure PodInfo where
  name : String
  ip : String
  port : Nat
  hostname : String := ""
  subdomain : String := ""
  «namespace» : String := ""
  ready : Bool := true
  /-- K8s node the pod is scheduled on ("" while Pending). -/
  nodeName : String := ""
  /-- True once the pod has a deletionTimestamp (Terminating). The pod is still
      in the pod list and (with a preStop drain) still alive+Ready, so dead
      detection won't fire — but the operator must drain it (promote a
      replacement, demote it to a live proxy) BEFORE it exits. -/
  terminating : Bool := false
  deriving Repr, BEq

/-- Convert a PodInfo to a node key matching the FQDN used by flared for registration.
    StatefulSet pods register as <hostname>.<subdomain>.<namespace>.svc.cluster.local:<port>. -/
def PodInfo.toNodeKey (p : PodInfo) : String :=
  if p.hostname != "" && p.subdomain != "" && p.«namespace» != "" then
    FlareClusterState.toNodeKey s!"{p.hostname}.{p.subdomain}.{p.«namespace»}.svc.cluster.local" p.port
  else
    FlareClusterState.toNodeKey p.ip p.port

-- ===========================================================================
-- Bridge Functions
-- ===========================================================================

/-- Fetch the FlareCluster CRD spec from K8s API.
    Wraps Kubectl.getFlareCluster with retry logic for resilience. -/
def getFlareClusterCRD (crName ns : String) : IO (Except String FlareClusterView) := do
  retry s!"fetch CRD {crName}" do
    getFlareCluster crName ns

/-- List flared pods matching the cluster label selector.
    Returns typed PodInfo list instead of raw tuples.
    Uses retry logic for resilience against transient API failures.

    kubectl get pods -n <ns> -l app=flare,cluster=<crName>
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP} 12121 {.status.conditions[?(.type=="Ready")].status}{\n}{end}' -/
def listFlaredPodsE (crName ns : String) : IO (Except String (List PodInfo)) := do
  let result ← retryConservative s!"list pods for {crName}" do
    kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={crName}",
             "-o", "jsonpath={range .items[*]}{.metadata.name} {.status.podIP} 12121 {.status.conditions[?(.type==\"Ready\")].status} {.spec.hostname} {.spec.subdomain} {.spec.nodeName}{\"\\n\"}{end}"]
  match result with
  | .error e => return .error e
  | .ok output =>
    let lines := output.splitOn "\n" |>.filter (· != "")
    let pods := lines.filterMap fun line =>
      let parts := line.splitOn " "
      match parts with
      | [podName, ip, portStr, readyStr, hostname, subdomain, nodeName] =>
        match portStr.trim.toNat? with
        | some port => some {
            name := podName.trim
            ip := ip.trim
            port := port
            hostname := hostname.trim
            subdomain := subdomain.trim
            «namespace» := ns
            ready := readyStr.trim == "True"
            nodeName := nodeName.trim
          }
        | none => none
      | [podName, ip, portStr, readyStr, hostname, subdomain] =>
        match portStr.trim.toNat? with
        | some port => some {
            name := podName.trim
            ip := ip.trim
            port := port
            hostname := hostname.trim
            subdomain := subdomain.trim
            «namespace» := ns
            ready := readyStr.trim == "True"
          }
        | none => none
      | [podName, ip, portStr, readyStr] =>
        match portStr.trim.toNat? with
        | some port => some {
            name := podName.trim
            ip := ip.trim
            port := port
            «namespace» := ns
            ready := readyStr.trim == "True"
          }
        | none => none
      | [podName, ip, portStr] =>
        match portStr.trim.toNat? with
        | some port => some {
            name := podName.trim
            ip := ip.trim
            port := port
            «namespace» := ns
            ready := true
          }
        | none => none
      | _ => none
    -- Second, lightweight query for Terminating pods (those with a
    -- deletionTimestamp). Kept SEPARATE from the positional space-split parse
    -- above: an empty deletionTimestamp emitted inline would collapse adjacent
    -- spaces and shift every field. Best-effort — on error, no pod is marked
    -- terminating (falls back to the pre-drain behaviour, never a false drain).
    -- List name + deletionTimestamp for EVERY pod and decide in code: a pod is
    -- Terminating iff its deletionTimestamp is non-empty. (kubectl jsonpath
    -- existence filters like [?(@.metadata.deletionTimestamp)] are unreliable, so
    -- we don't filter server-side.) A non-terminating pod emits just its name
    -- (empty timestamp collapses on trim) → one token → not terminating.
    let termResult ← retryConservative s!"list terminating pods for {crName}" do
      kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={crName}",
               "-o", "jsonpath={range .items[*]}{.metadata.name} {.metadata.deletionTimestamp}{\"\\n\"}{end}"]
    let termNames : List String := match termResult with
      | .ok out => out.splitOn "\n" |>.filterMap fun line =>
          match line.trim.splitOn " " |>.filter (· != "") with
          | [_name]      => none            -- name only, no timestamp → alive
          | name :: _ :: _ => some name     -- name + timestamp token → Terminating
          | []           => none
      | .error _ => []
    return .ok <| pods.map fun p =>
      if termNames.contains p.name then { p with terminating := true } else p

/-- Node keys of pods that are Terminating (have a deletionTimestamp). -/
def terminatingPodKeys (pods : List PodInfo) : List String :=
  (pods.filter (·.terminating)).map (·.toNodeKey)

/-- Failure-swallowing wrapper for callers where an empty answer is safe
    (topology broadcast just sends to nobody this tick). The RECONCILE path
    must NOT use this: an API failure fabricated as \"zero pods\" walks
    straight into dead-node detection. It uses listFlaredPodsE and aborts
    the cycle instead. -/
def listFlaredPods (crName ns : String) : IO (List PodInfo) := do
  match ← listFlaredPodsE crName ns with
  | .error _ => return []
  | .ok pods => return pods
/-- Patch a K8s Service selector to route traffic to a specific pod.
    Uses retry logic for resilience.

    kubectl patch svc <svcName> -n <ns> -p '{"spec":{"selector":{"statefulset.kubernetes.io/pod-name":"<podName>"}}}' -/
def patchClientServiceSelector (svcName ns podName : String) : IO (Except String Unit) := do
  retry s!"patch service {svcName}" do
    patchServiceSelector svcName ns podName

/-- Force-delete a pod by name.

    kubectl delete pod <podName> -n <ns> --grace-period=0 --force -/
def deletePod (podName ns : String) : IO (Except String Unit) := do
  let result ← kubectl ["delete", "pod", podName, "-n", ns,
                         "--grace-period=0", "--force"]
  match result with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- Update (or create) a ConfigMap with the current node-map data.
    Used to persist the operator's view of the cluster for observability.
    Uses retry logic for resilience.

    kubectl create configmap <name> -n <ns> --from-literal=nodeMap=<data> -o yaml --dry-run=client | kubectl apply -f - -/
def updateFlaredConfigMap (cmName ns : String) (nodeMapData : String) : IO (Except String Unit) := do
  retry s!"update configmap {cmName}" do
    -- Idempotent create-or-update WITHOUT a shell. `nodeMapData` contains node
    -- names sourced from untrusted TCP `node add` input, so it must never be
    -- interpolated into a `sh -c` string. We render the ConfigMap manifest with
    -- `kubectl create` (argv-direct: nodeMapData is a single argv element, not
    -- shell-parsed) and pipe the YAML to `kubectl apply -f -` over stdin.
    match ← kubectl ["create", "configmap", cmName, "-n", ns,
                     s!"--from-literal=nodeMap={nodeMapData}",
                     "-o", "yaml", "--dry-run=client"] with
    | .error e => return .error s!"configmap render failed: {e}"
    | .ok manifest =>
      match ← kubectlApplyManifest manifest with
      | .error e => return .error s!"configmap apply failed: {e}"
      | .ok _ => return .ok ()

-- ===========================================================================
-- Cluster Replication Bridge Functions
-- ===========================================================================

/-- Run a command inside a pod via kubectl exec. -/
def execInPod (podName ns : String) (cmd : List String) : IO (Except String String) := do
  kubectl (["exec", podName, "-n", ns, "--"] ++ cmd)

/-- Send SIGHUP to all pods in a cluster to trigger config reload.
    When flared receives SIGHUP, it re-registers with the index server (operator),
    receiving the full updated topology via the node sync response. -/
def sendSighupToPods (crName ns : String) : IO Unit := do
  let pods ← listFlaredPods crName ns
  for pod in pods do
    match ← execInPod pod.name ns ["kill", "-HUP", "1"] with
    | .error e =>
      IO.eprintln s!"[flare-operator] warning: SIGHUP to {pod.name} failed: {e}"
    | .ok _ => pure ()

/-- Single-pass check: does every flared pod's MOUNTED extra.conf already
    contain `needle`? kubelet propagates ConfigMap updates asynchronously
    (up to ~60-90s), so a SIGHUP sent right after `kubectl apply` makes
    flared re-read the OLD file. Callers SIGHUP immediately anyway (harmless,
    and correct when propagation happens to be fast), record the needle as
    pending, and re-run this check once per reconcile tick — re-signalling
    when it finally returns true. Never sleeps: one `cat` per pod, so the
    reconcile loop stays responsive (a blocking wait here once stalled the
    loop for minutes and starved every other reconcile duty). -/
def confLandedOnAllPods (crName ns needle : String) : IO Bool := do
  let pods ← listFlaredPods crName ns
  if pods.isEmpty then
    return false
  for pod in pods do
    match ← execInPod pod.name ns ["sh", "-c", "cat /etc/flared/extra.conf 2>/dev/null || true"] with
    | .ok content =>
      if (content.splitOn needle).length <= 1 then
        return false
    | .error _ => return false
  return true

/-- Render `extra.conf` content from rocksdb + optional cluster-replication
    sections. Sections are separated by a blank line when both are present so
    the file stays readable. Returns the empty string when neither section has
    anything to emit. -/
def renderFlaredExtraConf (rocksdb : RocksdbConfigSpec)
    (repl : Option ClusterReplicationSpec) : String :=
  let rocksdbBlock := rocksdb.toExtraConf
  let replBlock := match repl with
    | some r =>
      let enabled := if r.enabled then "true" else "false"
      String.intercalate "\n" [
        s!"cluster-replication = {enabled}",
        s!"cluster-replication-server-name = {r.serverName}",
        s!"cluster-replication-server-port = {r.port}",
        s!"cluster-replication-mode = {r.mode}",
        s!"cluster-replication-concurrency = {r.concurrency}"
      ]
    | none =>
      -- ALWAYS an explicit false, never omission: flared's SIGHUP reload
      -- only updates keys PRESENT in the file (ini_option::reload guards
      -- every assignment with opt_var_map.count), so silently REMOVING
      -- `cluster-replication = true` leaves a running flared replicating
      -- forever on its stale in-memory true. The classic flare-tools stop
      -- procedure was two-step ("= false" + reload, THEN remove + reload)
      -- for exactly this reason; an always-present explicit value collapses
      -- it into one declarative line.
      "cluster-replication = false"
  match rocksdbBlock, replBlock with
  | "", r  => r
  | a,  b  => a ++ "\n\n" ++ b

/-- Apply a ConfigMap named `{crName}-config` with the given `extra.conf`
    content via `kubectl create --dry-run=client -o yaml | kubectl apply -f -`.
    This is an upsert: it creates the ConfigMap if missing, or replaces its
    `extra.conf` key if present. -/
private def applyExtraConfConfigMap (crName ns content : String)
    : IO (Except String Unit) := do
  let cmName := s!"{crName}-config"
  -- Log content summary for production debugging (hash + byte count + first line).
  -- Full content is not logged to avoid leaking sensitive config values.
  let contentLines := content.splitOn "\n" |>.filter (· != "")
  let firstLine := contentLines.headD "(empty)"
  IO.eprintln s!"[flare-operator] ConfigMap {cmName}: {content.length} bytes, {contentLines.length} lines, first: {firstLine}"
  -- Shell-free create-or-update (see updateFlaredConfigMap). `content` is rendered
  -- from CRD-supplied values (replication server name etc.); keep it off `sh -c`.
  match ← kubectl ["create", "configmap", cmName, "-n", ns,
                   s!"--from-literal=extra.conf={content}",
                   "-o", "yaml", "--dry-run=client"] with
  | .error e => return .error s!"extra.conf configmap render failed: {e}"
  | .ok manifest =>
    match ← kubectlApplyManifest manifest with
    | .error e => return .error s!"extra.conf configmap apply failed: {e}"
    | .ok _ => return .ok ()

/-- Read the `extra.conf` key from `{crName}-config`, if present. -/
def readFlaredExtraConf (crName ns : String) : IO (Except String String) := do
  kubectl ["get", "configmap", s!"{crName}-config", "-n", ns,
           "-o", "jsonpath={.data.extra\\.conf}"]

/-- Update (or create) a ConfigMap with cluster replication config.
    ConfigMap name: {crName}-config, data key: "extra.conf".

    Preserves any rocksdb configuration passed in alongside the replication
    spec: the rendered file contains both sections when `rocksdb.hasAny` is
    true. -/
def updateFlaredReplicationConfig (crName ns : String) (repl : ClusterReplicationSpec)
    (rocksdb : RocksdbConfigSpec := {})
    : IO (Except String Unit) := do
  let content := renderFlaredExtraConf rocksdb (some repl)
  applyExtraConfConfigMap crName ns content

/-- Update (or create) the ConfigMap with only the rocksdb section.
    Used when cluster-replication is disabled but the CR still sets
    `spec.rocksdb.*` — we still need those lines in `extra.conf`.

    No-op (returns .ok) if `rocksdb.hasAny` is false: we do not want to
    overwrite a ConfigMap that may already contain other hand-edited keys
    when the user has not asked for any rocksdb tuning. -/
def updateFlaredRocksdbConfig (crName ns : String) (rocksdb : RocksdbConfigSpec)
    : IO (Except String Unit) := do
  if !rocksdb.hasAny then
    return .ok ()
  let content := renderFlaredExtraConf rocksdb none
  applyExtraConfConfigMap crName ns content

/-- Rewrite {cr}-config with the replication block DISABLED (rocksdb
    settings kept). Unlike updateFlaredRocksdbConfig this ALWAYS writes,
    even when rocksdb has nothing to say — the point is to flip the file to
    an explicit `cluster-replication = false` so the next SIGHUP actually
    stops a running replication (reload ignores ABSENT keys, so plain
    removal would leave flared replicating on its stale in-memory true). -/
def clearFlaredReplicationConfig (crName ns : String) (rocksdb : RocksdbConfigSpec := {})
    : IO (Except String Unit) :=
  applyExtraConfConfigMap crName ns (renderFlaredExtraConf rocksdb none)

/-- Read status.migrationPhase from the FlareCluster CR (None when unset
    or unreadable — safe default: a fresh cluster has no migration). -/
def readMigrationPhase (crName ns : String) : IO MigrationPhase := do
  match ← kubectl ["get", "flarecluster", crName, "-n", ns,
      "-o", "jsonpath={.status.migrationPhase}"] with
  | .ok s =>
    return (match s.trim with
      | "Dumping" => .Dumping
      | "Forwarding" => .Forwarding
      | _ => .None)
  | .error _ => return .None

/-- Update CRD status.migrationPhase via kubectl patch. -/
def patchFlareClusterStatus (crName ns : String) (phase : MigrationPhase)
    : IO (Except String Unit) := do
  let patch := s!"\{\"status\":\{\"migrationPhase\":\"{phase.toString}\"}}"
  let result ← kubectl ["patch", "flarecluster", crName, "-n", ns,
    "--subresource=status", "--type=merge", "-p", patch]
  match result with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- Query flared stats via kubectl exec and bash /dev/tcp. -/
def queryPodStats (podName ns : String) (statsCmd : String) : IO (Except String String) :=
  execInPod podName ns ["bash", "-c", s!"exec 3<>/dev/tcp/localhost/12121; printf '{statsCmd}\\r\\n' >&3; timeout 3 cat <&3; exec 3>&-"]

/-- LEVEL-TRIGGERED replication reconciliation: for every flared pod whose
    MOUNTED extra.conf already carries `needle` but whose RUNTIME state
    (per the `cluster_replication` / `cluster_replication_mode` stats) does
    not match the desired (enabled, mode), send a targeted SIGHUP.

    This is the durable replacement for relying solely on the one-shot
    write+SIGHUP+pendingConf chain: that re-signal lives in operator memory,
    and losing it (restart, give-up, leader change) used to leave flared
    running the OLD replication config forever — observed live as a
    migration's Duplicating phase sitting at 0 keys for 107 minutes because
    flared had reloaded `cluster_replication: false -> false` moments before
    the ConfigMap mount caught up, and no second SIGHUP ever came.

    Returns the number of pods nudged. Safe to call every tick: a pod in
    the desired state is never signalled, and a pod whose mount has not
    propagated yet is skipped (SIGHUPing it would just re-apply old values;
    the next tick retries). -/
def resignalReplicationDrift (crName ns needle : String)
    (wantEnabled : Bool) (wantMode : String) : IO Nat := do
  let pods ← listFlaredPods crName ns
  let mut nudged := 0
  for pod in pods do
    -- mounted file first: only pods that CAN apply the desired config
    let mounted : Bool ← do
      match ← execInPod pod.name ns ["sh", "-c", "cat /etc/flared/extra.conf 2>/dev/null || true"] with
      | .ok content => pure (decide ((content.splitOn needle).length > 1))
      | .error _ => pure false
    if mounted then
      match ← queryPodStats pod.name ns "stats" with
      | .error _ => pure ()  -- unreadable pod: not ours to fix this tick
      | .ok out =>
        let lines := out.splitOn "\n" |>.map (fun l => l.trim.replace "\r" "")
        let stat (k : String) : Option String :=
          lines.findSome? fun l =>
            if l.startsWith s!"STAT {k} " then some (l.drop (s!"STAT {k} ".length)) else none
        -- flared without the stat (pre-rc32) is unobservable: skip rather
        -- than SIGHUP-spamming it every pass on a permanent "mismatch".
        let observable := (stat "cluster_replication").isSome
        let appliedOn := (stat "cluster_replication").getD "off" == "on"
        let appliedMode := (stat "cluster_replication_mode").getD ""
        let ok := if wantEnabled then appliedOn && appliedMode == wantMode else !appliedOn
        if observable && !ok then
          IO.eprintln s!"[flare-operator] replication drift on {pod.name} (applied on={appliedOn} mode={appliedMode}, want enabled={wantEnabled} mode={wantMode}) -> SIGHUP"
          match ← execInPod pod.name ns ["kill", "-HUP", "1"] with
          | .error e => IO.eprintln s!"[flare-operator] warning: drift SIGHUP to {pod.name} failed: {e}"
          | .ok _ => nudged := nudged + 1
  return nudged

-- ===========================================================================
-- Convenience: extract live node keys from PodInfo list
-- ===========================================================================

/-- Extract node keys from all existing pods (not just ready ones).
    A pod that exists but isn't ready is probably restarting, not dead.
    Dead detection should only trigger for pods that are completely gone. -/
def liveNodeKeys (pods : List PodInfo) : List String :=
  pods.map PodInfo.toNodeKey

/-- K8s node name → zone, from the well-known topology label. Nodes without
    the label are omitted; on unlabeled clusters (kind) this is []. -/
def listNodeZones : IO (List (String × String)) := do
  let result ← retryConservative "list node zones" do
    kubectl ["get", "nodes",
             "-o", "jsonpath={range .items[*]}{.metadata.name} {.metadata.labels.topology\\.kubernetes\\.io/zone}{\"\\n\"}{end}"]
  match result with
  | .error e =>
    -- Loud on purpose: a silently-empty zone list once hid a missing
    -- nodes RBAC rule and quietly disabled zone-aware placement. Real
    -- label-less clusters return .ok with empty output and stay silent.
    IO.eprintln s!"[flare-operator] WARNING: could not list node zones ({e}) — zone-aware placement disabled this cycle"
    return []
  | .ok output =>
    return output.splitOn "\n" |>.filterMap fun line =>
      match line.trim.splitOn " " with
      | [node, zone] => if zone.isEmpty then none else some (node, zone)
      | _ => none

/-- nodeKey → zone for every pod scheduled on a zone-labeled node. -/
def podZones (pods : List PodInfo) (nodeZones : List (String × String))
    : List (String × String) :=
  pods.filterMap fun p =>
    if p.nodeName.isEmpty then none
    else (nodeZones.lookup p.nodeName).map fun z => (p.toNodeKey, z)

/-- Read the nodeMap data from a ConfigMap.
    kubectl get configmap <name> -n <ns> -o jsonpath='{.data.nodeMap}' -/
def readFlaredConfigMap (cmName ns : String) : IO (Except String String) :=
  kubectl ["get", "configmap", cmName, "-n", ns, "-o", "jsonpath={.data.nodeMap}"]

-- ===========================================================================
-- Lease API Functions (leader election)
-- ===========================================================================

/-- Lease information returned from K8s API. -/
structure LeaseInfo where
  holderIdentity : String
  leaseDurationSeconds : Nat
  expired : Bool
  /-- metadata.resourceVersion at read time — the optimistic-concurrency
      token for takeover (see acquireLease). -/
  resourceVersion : String := ""
  /-- spec.leaseTransitions: the leadership GENERATION. Incremented by
      every takeover; the fencing token (see Main's version composition). -/
  transitions : Nat := 0
  deriving Repr, BEq

/-- Get lease info including expiry check.
    Uses shell date arithmetic to determine if the lease has expired. -/
def getLease (leaseName ns : String) : IO (Except String LeaseInfo) := do
  try
    -- ONE kubectl GET for every field (holder, duration, renewTime,
    -- resourceVersion): the previous three separate reads were not a
    -- consistent snapshot — holder/renewTime could come from different
    -- lease generations. resourceVersion from this same read is the
    -- optimistic-concurrency token a takeover must present (review P1-2).
    let result ← IO.Process.output {
      cmd := "timeout"
      args := #["-k", "5", "30", "sh", "-c",
        s!"OUT=$(kubectl get lease {leaseName} -n {ns} -o jsonpath='\{.spec.holderIdentity}\{\"|\"}\{.spec.leaseDurationSeconds}\{\"|\"}\{.spec.renewTime}\{\"|\"}\{.metadata.resourceVersion}\{\"|\"}\{.spec.leaseTransitions}') || exit 1; RENEW=$(printf %s \"$OUT\" | cut -d'|' -f3); RENEW_EPOCH=$(date -d \"$RENEW\" +%s 2>/dev/null || echo 0); NOW_EPOCH=$(date -u +%s); echo \"$OUT|$((NOW_EPOCH - RENEW_EPOCH))\""]
    }
    if result.exitCode != 0 then
      return .error s!"getLease failed (exit {result.exitCode}): {result.stderr}"
    let parts := result.stdout.trim.splitOn "|"
    match parts with
    | [holder, durStr, _renew, rv, transStr, ageStr] =>
      let dur := durStr.trim.toNat?.getD 15
      let age := ageStr.trim.toNat?.getD 0
      return .ok { holderIdentity := holder.trim, leaseDurationSeconds := dur,
                   expired := age ≥ dur, resourceVersion := rv.trim,
                   transitions := transStr.trim.toNat?.getD 0 }
    | _ => return .error s!"unexpected getLease output: {result.stdout}"
  catch e =>
    return .error s!"getLease error: {e}"

/-- Create a new lease atomically. Fails with error if lease already exists.
    Uses kubectl create (NOT apply) for atomic create-or-fail semantics. -/
def createLease (leaseName ns identity : String) (durationSec : Nat) : IO (Except String Unit) := do
  try
    let nowResult ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%S.000000Z"] }
    let now := nowResult.stdout.trim
    let result ← IO.Process.output {
      cmd := "timeout"
      args := #["-k", "5", "30", "sh", "-c",
        s!"echo 'apiVersion: coordination.k8s.io/v1\nkind: Lease\nmetadata:\n  name: {leaseName}\n  namespace: {ns}\nspec:\n  holderIdentity: {identity}\n  leaseDurationSeconds: {durationSec}\n  leaseTransitions: 1\n  acquireTime: \"{now}\"\n  renewTime: \"{now}\"' | kubectl create -f -"]
    }
    if result.exitCode == 0 then
      return .ok ()
    else
      return .error s!"createLease failed (exit {result.exitCode}): {result.stderr}"
  catch e =>
    return .error s!"createLease error: {e}"

/-- Renew lease using JSON Patch with test-and-set semantics.
    The test op rejects the patch if holderIdentity changed (CAS). -/
def renewLease (leaseName ns identity : String) : IO (Except String Unit) := do
  try
    let nowResult ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%S.000000Z"] }
    let now := nowResult.stdout.trim
    let patch := s!"[\{\"op\":\"test\",\"path\":\"/spec/holderIdentity\",\"value\":\"{identity}\"},\{\"op\":\"replace\",\"path\":\"/spec/renewTime\",\"value\":\"{now}\"}]"
    let result ← kubectl ["patch", "lease", leaseName, "-n", ns, "--type=json", "-p", patch]
    match result with
    | .error e => return .error e
    | .ok _ => return .ok ()
  catch e =>
    return .error s!"renewLease error: {e}"

/-- Acquire an expired lease using JSON Patch with test-and-set.

    The precondition is the lease's metadata.resourceVersion from the SAME
    read that judged it expired: any write in between — in particular the
    old holder renewing at the last moment — bumps the resourceVersion and
    makes this patch fail, so a live lease can never be stolen. (Testing
    only holderIdentity was racy: a renewal does not change the holder, so
    the old test passed even after the holder had just renewed — external
    review P1-2.) The holder test is kept as defense in depth. -/
def acquireLease (leaseName ns newIdentity oldIdentity resourceVersion : String)
    (durationSec : Nat) (newTransitions : Nat := 0) : IO (Except String Unit) := do
  try
    let nowResult ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%S.000000Z"] }
    let now := nowResult.stdout.trim
    -- leaseTransitions is the leadership GENERATION (fencing token):
    -- bumped on every takeover, never on renewal. "add" upserts, so leases
    -- created before this field existed are handled too.
    let patch := s!"[\{\"op\":\"test\",\"path\":\"/metadata/resourceVersion\",\"value\":\"{resourceVersion}\"},\{\"op\":\"test\",\"path\":\"/spec/holderIdentity\",\"value\":\"{oldIdentity}\"},\{\"op\":\"replace\",\"path\":\"/spec/holderIdentity\",\"value\":\"{newIdentity}\"},\{\"op\":\"replace\",\"path\":\"/spec/renewTime\",\"value\":\"{now}\"},\{\"op\":\"replace\",\"path\":\"/spec/acquireTime\",\"value\":\"{now}\"},\{\"op\":\"replace\",\"path\":\"/spec/leaseDurationSeconds\",\"value\":{durationSec}},\{\"op\":\"add\",\"path\":\"/spec/leaseTransitions\",\"value\":{newTransitions}}]"
    let result ← kubectl ["patch", "lease", leaseName, "-n", ns, "--type=json", "-p", patch]
    match result with
    | .error e => return .error e
    | .ok _ => return .ok ()
  catch e =>
    return .error s!"acquireLease error: {e}"

end FlareOperator.K8s.Bridge
