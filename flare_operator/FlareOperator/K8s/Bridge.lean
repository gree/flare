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
def listFlaredPods (crName ns : String) : IO (List PodInfo) := do
  let result ← retryConservative s!"list pods for {crName}" do
    kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={crName}",
             "-o", "jsonpath={range .items[*]}{.metadata.name} {.status.podIP} 12121 {.status.conditions[?(.type==\"Ready\")].status} {.spec.hostname} {.spec.subdomain}{\"\\n\"}{end}"]
  match result with
  | .error _ => return []
  | .ok output =>
    let lines := output.splitOn "\n" |>.filter (· != "")
    return lines.filterMap fun line =>
      let parts := line.splitOn " "
      match parts with
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
    -- Use kubectl apply with dry-run pipe pattern for idempotent create-or-update
    try
      let result ← IO.Process.output {
        cmd := "sh"
        args := #["-c",
          s!"kubectl create configmap {cmName} -n {ns} --from-literal=nodeMap='{nodeMapData}' -o yaml --dry-run=client | kubectl apply -f -"]
      }
      if result.exitCode == 0 then
        return .ok ()
      else
        return .error s!"configmap update failed (exit {result.exitCode}): {result.stderr}"
    catch e =>
      return .error s!"configmap update error: {e}"

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

/-- Render `extra.conf` content from rocksdb + optional cluster-replication
    sections. Sections are separated by a blank line when both are present so
    the file stays readable. Returns the empty string when neither section has
    anything to emit. -/
def renderFlaredExtraConf (rocksdb : RocksdbConfigSpec)
    (repl : Option ClusterReplicationSpec) : String :=
  let rocksdbBlock := rocksdb.toExtraConf
  let replBlock := match repl with
    | some r =>
      String.intercalate "\n" [
        s!"cluster-replication = true",
        s!"cluster-replication-server-name = {r.serverName}",
        s!"cluster-replication-server-port = {r.port}",
        s!"cluster-replication-mode = {r.mode}",
        s!"cluster-replication-concurrency = {r.concurrency}"
      ]
    | none => ""
  match rocksdbBlock, replBlock with
  | "", "" => ""
  | "", r  => r
  | r,  "" => r
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
  try
    let result ← IO.Process.output {
      cmd := "sh"
      args := #["-c",
        s!"kubectl create configmap {cmName} -n {ns} --from-literal='extra.conf={content}' -o yaml --dry-run=client | kubectl apply -f -"]
    }
    if result.exitCode == 0 then
      return .ok ()
    else
      return .error s!"extra.conf configmap apply failed (exit {result.exitCode}): {result.stderr}"
  catch e =>
    return .error s!"extra.conf configmap apply error: {e}"

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

-- ===========================================================================
-- Convenience: extract live node keys from PodInfo list
-- ===========================================================================

/-- Extract node keys from all existing pods (not just ready ones).
    A pod that exists but isn't ready is probably restarting, not dead.
    Dead detection should only trigger for pods that are completely gone. -/
def liveNodeKeys (pods : List PodInfo) : List String :=
  pods.map PodInfo.toNodeKey

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
  deriving Repr, BEq

/-- Get lease info including expiry check.
    Uses shell date arithmetic to determine if the lease has expired. -/
def getLease (leaseName ns : String) : IO (Except String LeaseInfo) := do
  try
    let result ← IO.Process.output {
      cmd := "sh"
      args := #["-c",
        s!"HOLDER=$(kubectl get lease {leaseName} -n {ns} -o jsonpath='\{.spec.holderIdentity}') && DUR=$(kubectl get lease {leaseName} -n {ns} -o jsonpath='\{.spec.leaseDurationSeconds}') && RENEW=$(kubectl get lease {leaseName} -n {ns} -o jsonpath='\{.spec.renewTime}') && RENEW_EPOCH=$(date -d \"$RENEW\" +%s 2>/dev/null || echo 0) && NOW_EPOCH=$(date -u +%s) && if [ $((NOW_EPOCH - RENEW_EPOCH)) -ge \"$DUR\" ]; then EXP=true; else EXP=false; fi && echo \"$HOLDER|$DUR|$EXP\""]
    }
    if result.exitCode != 0 then
      return .error s!"getLease failed (exit {result.exitCode}): {result.stderr}"
    let parts := result.stdout.trim.splitOn "|"
    match parts with
    | [holder, durStr, expStr] =>
      let dur := durStr.trim.toNat?.getD 15
      let expired := expStr.trim == "true"
      return .ok { holderIdentity := holder.trim, leaseDurationSeconds := dur, expired := expired }
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
      cmd := "sh"
      args := #["-c",
        s!"echo 'apiVersion: coordination.k8s.io/v1\nkind: Lease\nmetadata:\n  name: {leaseName}\n  namespace: {ns}\nspec:\n  holderIdentity: {identity}\n  leaseDurationSeconds: {durationSec}\n  acquireTime: \"{now}\"\n  renewTime: \"{now}\"' | kubectl create -f -"]
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
    Tests that holderIdentity matches oldIdentity to prevent race conditions. -/
def acquireLease (leaseName ns newIdentity oldIdentity : String) (durationSec : Nat)
    : IO (Except String Unit) := do
  try
    let nowResult ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%S.000000Z"] }
    let now := nowResult.stdout.trim
    let patch := s!"[\{\"op\":\"test\",\"path\":\"/spec/holderIdentity\",\"value\":\"{oldIdentity}\"},\{\"op\":\"replace\",\"path\":\"/spec/holderIdentity\",\"value\":\"{newIdentity}\"},\{\"op\":\"replace\",\"path\":\"/spec/renewTime\",\"value\":\"{now}\"},\{\"op\":\"replace\",\"path\":\"/spec/acquireTime\",\"value\":\"{now}\"},\{\"op\":\"replace\",\"path\":\"/spec/leaseDurationSeconds\",\"value\":{durationSec}}]"
    let result ← kubectl ["patch", "lease", leaseName, "-n", ns, "--type=json", "-p", patch]
    match result with
    | .error e => return .error e
    | .ok _ => return .ok ()
  catch e =>
    return .error s!"acquireLease error: {e}"

end FlareOperator.K8s.Bridge
