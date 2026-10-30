/-
  Bridge.lean - High-level K8s kubectl bridge

  Wraps the low-level kubectl subprocess calls from Kubectl.lean into
  typed, operator-specific operations. Each function issues exactly one
  kubectl call and returns a typed result.

  Functions:
  - getFlareClusterCRD: fetch CRD spec as FlareClusterView
  - listFlaredPods: list pods with PodInfo (name, ip, port, ready)
  - patchClientServiceSelector: point a Service at a specific pod
  - updateFlaredConfigMap: update a ConfigMap with node-map data
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.K8s.Retry
import FlareOperator.Kubectl
import Lean.Data.Json
import FlareOperator.StateMachine.ReplicaRepair
import FlareOperator.StateMachine.Handover
import FlareOperator.StateMachine.NodeMove

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
  /-- SAF-08 incarnation: the pod UID and the flared container's restart
      count (a restarted flared is a container restart). "" / none when not
      observed. -/
  uid : String := ""
  restarts : Option Nat := none
  /-- the StatefulSet revision the pod was created from
      (controller-revision-hash); "" when not labelled -/
  revision : String := ""
  /-- carries the `flare.gree.net/serving` label (the client Service selects it) -/
  serving : Bool := false
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

/-- Parse the single-response pod list (see listFlaredPodsE). A row whose
    column count is wrong is dropped rather than guessed. -/
def parsePodRows (ns output : String) : List PodInfo :=
  (output.splitOn "\n").filterMap fun line =>
    let row := fun (name ip ready hostname subdomain nodeName uid rc ts rev serving : String) =>
      if name.trim.isEmpty then none
      else some ({
        name := name.trim, ip := ip.trim, port := 12121,
        hostname := hostname.trim, subdomain := subdomain.trim, «namespace» := ns,
        ready := ready.trim == "True", nodeName := nodeName.trim,
        terminating := !ts.trim.isEmpty, uid := uid.trim, restarts := rc.trim.toNat?,
        revision := rev.trim, serving := serving.trim == "true" } : PodInfo)
    match line.trim.splitOn "|" with
    | [name, ip, ready, hostname, subdomain, nodeName, uid, rc, ts, rev, serving] =>
      row name ip ready hostname subdomain nodeName uid rc ts rev serving
    | [name, ip, ready, hostname, subdomain, nodeName, uid, rc, ts, rev] =>
      row name ip ready hostname subdomain nodeName uid rc ts rev ""
    | [name, ip, ready, hostname, subdomain, nodeName, uid, rc, ts] =>
      row name ip ready hostname subdomain nodeName uid rc ts "" ""
    | _ => none

/-- List flared pods matching the cluster label selector.
    Returns typed PodInfo list instead of raw tuples.
    Uses retry logic for resilience against transient API failures.

    kubectl get pods -n <ns> -l app=flare,cluster=<crName>
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP} 12121 {.status.conditions[?(.type=="Ready")].status}{\n}{end}' -/
def listFlaredPodsE (crName ns : String) : IO (Except String (List PodInfo)) := do
  -- ONE response for every field (SAF-08, review 2026-10-05): Ready, UID,
  -- container restart count and deletionTimestamp used to come from two
  -- list calls joined by pod name, so a pod replaced under the same name
  -- between them combined the OLD pod's Ready with the NEW pod's UID. One
  -- jsonpath over the same items is one consistent snapshot per pod.
  -- '|'-separated so an empty field (no IP while Pending, no restartCount,
  -- no deletionTimestamp) keeps every column in place.
  let result ← retryConservative s!"list pods for {crName}" do
    kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={crName}",
             "-o", "jsonpath={range .items[*]}{.metadata.name}|{.status.podIP}|{.status.conditions[?(.type==\"Ready\")].status}|{.spec.hostname}|{.spec.subdomain}|{.spec.nodeName}|{.metadata.uid}|{.status.containerStatuses[0].restartCount}|{.metadata.deletionTimestamp}|{.metadata.labels.controller-revision-hash}|{.metadata.labels.flare\\.gree\\.net/serving}{\"\\n\"}{end}"]
  match result with
  | .error e => return .error e
  | .ok output => return .ok (parsePodRows ns output)

/-- The StatefulSet's update revision (status.updateRevision): the revision
    every pod must be created from. With updateStrategy OnDelete the
    operator replaces the pods that are not on it (A0). -/
def statefulSetUpdateRevision (stsName ns : String) : IO (Except String String) := do
  match ← kubectl ["get", "statefulset", stsName, "-n", ns, "-o", "jsonpath={.status.updateRevision}"] with
  | .ok out =>
    if out.trim.isEmpty then return .error s!"statefulset {stsName} has no updateRevision yet"
    else return .ok out.trim
  | .error e => return .error e

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

/-- GRACEFUL pod deletion (no force, full grace period): the pod goes
    Terminating with its full preStop window, so the operator's drain path
    sees it and performs the demote+promote handoff. Used by the empty-master
    self-heal — the whole point is to route through the PROVEN drain
    machinery instead of yanking the pod out from under it. -/
def deletePodGraceful (podName ns : String) : IO (Except String Unit) := do
  match ← kubectl ["delete", "pod", podName, "-n", ns, "--wait=false"] with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- metadata.uid of a pod, or none if it cannot be read (absent, API error). -/
def podUid (podName ns : String) : IO (Option String) := do
  match ← kubectl ["get", "pod", podName, "-n", ns, "-o", "jsonpath={.metadata.uid}"] with
  | .ok out => let u := out.trim; return (if u.isEmpty then none else some u)
  | .error _ => return none

/-- Short-budget, read-only API calls for the round-robin topology audit.
    Do not inherit the generic kubectl 30-second budget three times per pass. -/
private def topologyProbeCommand (seconds : Nat) (args : Array String) : IO (Option String) := do
  try
    let r ← IO.Process.output {
      cmd := "timeout"
      args := #["-k", "1", toString seconds, "kubectl"] ++ args }
    return if r.exitCode == 0 then some r.stdout else none
  catch _ => return none

/-- TEST SEAM (SAF-08 / CHECK-01-observation E2E). Unset in production, this
    is one getEnv per probe. When `FLARE_TEST_PROBE_BARRIER` names a
    directory and `<dir>/probe-arm-<pod>` exists, the probe of THAT pod stops
    after its first UID read: it writes the UID it read to
    `<dir>/probe-reached`, removes the arm file, and waits for
    `<dir>/probe-release` (at most 30 s, so a stale arm file cannot wedge the
    loop that also renews the lease). The E2E replaces the pod under the same
    name while the probe is held, which is the race the UID bracket exists
    for. -/
private def probeBarrier (podName uid : String) : IO Unit := do
  match ← IO.getEnv "FLARE_TEST_PROBE_BARRIER" with
  | none => pure ()
  | some dir =>
    let arm : System.FilePath := dir ++ s!"/probe-arm-{podName}"
    if !(← arm.pathExists) then pure ()
    else
      let reached : System.FilePath := dir ++ "/probe-reached"
      let release : System.FilePath := dir ++ "/probe-release"
      IO.eprintln s!"[flare-operator] TEST SEAM: topology probe of {podName} held after the first UID read (uid={uid})"
      try IO.FS.writeFile reached s!"{uid}\n" catch _ => pure ()
      try IO.FS.removeFile arm catch _ => pure ()
      let mut released := false
      for _ in [0:300] do        -- 300 x 100ms = 30s ceiling
        if (← release.pathExists) then
          released := true
          break
        IO.sleep 100
      IO.eprintln s!"[flare-operator] TEST SEAM: topology probe of {podName} {if released then "released" else "timed out after 30s"}"
      try IO.FS.removeFile release catch _ => pure ()
      try IO.FS.removeFile reached catch _ => pure ()

/-- Bracket a stats reply with Pod UID reads. No cached result is reused.
    Command payload is fixed; pod/namespace are separate argv elements. -/
def topologyProbe (podName ns : String) : IO (Option String × Option String × Option String) := do
  let args := #["get", "pod", podName, "-n", ns, "-o", "jsonpath={.metadata.uid}"]
  let before := (← topologyProbeCommand 2 args).map String.trim
  if before.isNone || before == some "" then return (none, none, none)
  probeBarrier podName (before.getD "")
  let reply ← topologyProbeCommand 3 #["exec", "-n", ns, podName, "--", "bash", "-c",
    "exec 3<>/dev/tcp/localhost/12121; printf 'stats\\r\\n' >&3; while IFS= read -r line; do printf '%s\\n' \"$line\"; case \"$line\" in END*) break;; esac; done <&3; exec 3>&-"]
  let after := (← topologyProbeCommand 2 args).map String.trim
  return (before, after, reply)

/-- The shell command that deletes a pod with the observed UID as an API-side
    PRECONDITION (DeleteOptions.preconditions.uid), so the apiserver itself
    rejects the request (409 Conflict) if a pod of the same name now has a
    different UID. `kubectl delete` cannot send a DeleteOptions body, so this
    speaks to the API directly with the pod's service-account token. Exposed
    as a pure string so the E2E harness can run the exact same command inside
    the operator pod against a replaced pod and prove the refusal. Prints the
    HTTP status on the last line. -/
def uidPreconditionDeleteCommand (podName ns uid : String)
    (apiBase : String := "https://kubernetes.default.svc") : String :=
  let sa := "/var/run/secrets/kubernetes.io/serviceaccount"
  let body := s!"\{\"apiVersion\":\"meta.k8s.io/v1\",\"kind\":\"DeleteOptions\",\"preconditions\":\{\"uid\":\"{uid}\"},\"propagationPolicy\":\"Background\"}"
  -- DEADLINES (review): --connect-timeout bounds the TCP/TLS connect,
  -- --max-time bounds the whole exchange, so a server that accepts and then
  -- never answers cannot stall the reconcile (and with it the lease renewal).
  -- curl's own exit code is printed after the status so the caller can tell
  -- "timed out" (28) from an HTTP refusal.
  s!"curl -sS -X DELETE --connect-timeout 3 --max-time 10 --cacert {sa}/ca.crt -H \"Authorization: Bearer $(cat {sa}/token)\" -H 'Content-Type: application/json' -d '{body}' -w '\n%\{http_code}' {apiBase}/api/v1/namespaces/{ns}/pods/{podName}; echo \"\ncurl_exit=$?\""

/-- Delete a pod ONLY IF its UID equals `expectedUid`, enforced by the API
    server (review item 1: a client-side re-read followed by a name delete
    still races a same-name replacement). 200/202 = deleted; 409 = the
    precondition failed, i.e. a different pod now holds the name; 404 =
    already gone. -/
def deletePodWithUidPrecondition (podName ns expectedUid : String) : IO (Except String Unit) := do
  -- Outer wall as well (same policy as the kubectl wrapper): SIGTERM at 20s,
  -- SIGKILL 5s later, so this call returns within ~25s whatever curl does.
  -- A timeout or transport failure does NOT mean "not deleted": the API may
  -- have accepted the delete and only the response was lost. The outcome is
  -- UNKNOWN; the caller must re-observe the pod before deciding anything.
  let out ← IO.Process.output { cmd := "timeout", args := #["-k", "5", "20", "sh", "-c", uidPreconditionDeleteCommand podName ns expectedUid] }
  if out.exitCode == 124 then
    return .error s!"delete with UID precondition for {podName} hit the wall (20s, +5s kill grace) with no answer from the API: deletion outcome UNKNOWN — re-observe the pod before any retry"
  let lines := (out.stdout.splitOn "\n").filter (· != "")
  let curlExit := (lines.find? (·.startsWith "curl_exit=")).map (·.drop "curl_exit=".length) |>.getD "?"
  let code := ((lines.filter (fun l => !l.startsWith "curl_exit=")).getLast?.getD "").trim
  if curlExit != "0" then
    return .error s!"delete with UID precondition for {podName}: transport failure (curl exit {curlExit}: {out.stderr.trim}); deletion outcome UNKNOWN — the API may have accepted it and only the answer was lost; re-observe the pod before any retry"
  match code with
  | "200" | "202" => return .ok ()
  | "409" => return .error s!"apiserver refused: pod {podName} no longer has UID {expectedUid} (precondition failed; a replacement holds the name) — not deleted"
  | "404" => return .error s!"pod {podName} is already gone"
  | _ => return .error s!"delete with UID precondition failed (http {code}): {out.stderr.trim}"

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
    (repl : Option ClusterReplicationSpec) (offSnapshotPush : Bool := true) : String :=
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
      ] ++ (if r.snapshotPush then "" else "\ncluster-replication-snapshot-push = false")
    | none =>
      -- ALWAYS an explicit false, never omission: flared's SIGHUP reload
      -- only updates keys PRESENT in the file (ini_option::reload guards
      -- every assignment with opt_var_map.count), so silently REMOVING
      -- `cluster-replication = true` leaves a running flared replicating
      -- forever on its stale in-memory true. The classic flare-tools stop
      -- procedure was two-step ("= false" + reload, THEN remove + reload)
      -- for exactly this reason; an always-present explicit value collapses
      -- it into one declarative line.
      -- With replication off the snapshot-push switch is still rendered
      -- when the CR sets it false: flared then REFUSES an incoming push
      -- (destination side, user decision 2026-10-13 item 1). Default true
      -- renders nothing (file unchanged).
      "cluster-replication = false" ++ (if offSnapshotPush then "" else "\ncluster-replication-snapshot-push = false")
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
    (offSnapshotPush : Bool := true)
    : IO (Except String Unit) := do
  if !rocksdb.hasAny && offSnapshotPush then
    return .ok ()
  let content := renderFlaredExtraConf rocksdb none offSnapshotPush
  applyExtraConfConfigMap crName ns content

/-- Rewrite {cr}-config with the replication block DISABLED (rocksdb
    settings kept). Unlike updateFlaredRocksdbConfig this ALWAYS writes,
    even when rocksdb has nothing to say — the point is to flip the file to
    an explicit `cluster-replication = false` so the next SIGHUP actually
    stops a running replication (reload ignores ABSENT keys, so plain
    removal would leave flared replicating on its stale in-memory true). -/
def clearFlaredReplicationConfig (crName ns : String) (rocksdb : RocksdbConfigSpec := {})
    (offSnapshotPush : Bool := true)
    : IO (Except String Unit) :=
  applyExtraConfConfigMap crName ns (renderFlaredExtraConf rocksdb none offSnapshotPush)

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

/-- The replica-repair ledger persisted in `status.replicaRepairs` (SC-03 /
    SAF-05): pending requests AND last-seen drop counters, so an operator
    restart neither forgets a repair nor re-baselines the counters.

    Three outcomes, kept distinct on purpose (item 4): `.ok none` = the CR
    has no ledger (a fresh cluster: start with baselines); `.ok (some l)` =
    restored; `.error` = the API call failed, the reply did not parse, or
    the stored ledger is corrupt. An error must NOT be treated as absence —
    starting from an empty ledger over a pending request loses the request
    and re-baselines the counters, so the caller retries and holds repair
    actions until a read succeeds. -/
def readRepairLedger (crName ns : String) : IO (Except String (Option ReplicaRepair.Ledger)) := do
  match ← kubectl ["get", "flarecluster", crName, "-n", ns, "-o", "json"] with
  | .error e => return .error s!"ledger read failed: {e}"
  | .ok out =>
    match Lean.Json.parse out with
    | .error e => return .error s!"ledger read: CR JSON did not parse: {e}"
    | .ok j =>
      match j.getObjVal? "status" >>= (·.getObjVal? "replicaRepairs") with
      | .error _ => return .ok none
      | .ok r =>
        match ReplicaRepair.Ledger.fromJson? r with
        | some l => return .ok (some l)
        | none => return .error "ledger read: status.replicaRepairs is present but does not parse (corrupt); refusing to start from an empty ledger"

/-- Persist the ledger (merge patch on the status subresource; the whole
    object is rewritten, arrays included). -/
def writeRepairLedger (crName ns : String) (l : ReplicaRepair.Ledger) : IO (Except String Unit) := do
  let patch := (Lean.Json.mkObj [("status", Lean.Json.mkObj [("replicaRepairs", l.toJson)])]).compress
  match ← kubectl ["patch", "flarecluster", crName, "-n", ns,
      "--subresource=status", "--type=merge", "-p", patch] with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- The handover ledger persisted in `status.handovers` (flare-lossless-
    handover): an operator restart resumes a handover where it was (a map V1
    already sent is always finished by a promote or a rollback). Same three
    outcomes as the repair ledger: absent, restored, or an error that must
    not be taken for absence. -/
def readHandovers (crName ns : String) : IO (Except String (Option Handover.Ledger)) := do
  match ← kubectl ["get", "flarecluster", crName, "-n", ns, "-o", "json"] with
  | .error e => return .error s!"handover read failed: {e}"
  | .ok out =>
    match Lean.Json.parse out with
    | .error e => return .error s!"handover read: CR JSON did not parse: {e}"
    | .ok j =>
      match j.getObjVal? "status" >>= (·.getObjVal? "handovers") with
      | .error _ => return .ok none
      | .ok r =>
        match Handover.Ledger.fromJson? r with
        | some l => return .ok (some l)
        | none => return .error "handover read: status.handovers is present but does not parse (corrupt)"

def writeHandovers (crName ns : String) (l : Handover.Ledger) : IO (Except String Unit) := do
  let patch := (Lean.Json.mkObj [("status", Lean.Json.mkObj [("handovers", l.toJson)])]).compress
  match ← kubectl ["patch", "flarecluster", crName, "-n", ns,
      "--subresource=status", "--type=merge", "-p", patch] with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- How many stats connections the operator opened to each pod (every
    `queryPodStats` is one connection to flared, and flared counts it in
    `total_connections`). The cordon move subtracts them: it asks whether
    CLIENTS still connect, not whether the operator did. -/
initialize statsProbeCount : IO.Ref (List (String × Nat)) ← IO.mkRef []

def probesTo (pod : String) : IO Nat := do
  return ((← statsProbeCount.get).lookup pod).getD 0

/-- Query flared stats via kubectl exec and bash /dev/tcp. -/
def queryPodStats (podName ns : String) (statsCmd : String) : IO (Except String String) := do
  statsProbeCount.modify fun l => (podName, (l.lookup podName).getD 0 + 1) :: l.filter (·.1 != podName)
  -- Read until the END line and return at once; the connection would stay
  -- open (memcached protocol), so a plain `cat` always ran into its 3 s
  -- timeout and every stats probe cost ≥3 s of reconcile time. The overall
  -- deadline stays (timeout 3), so a hung or silent flared still bounds it.
  execInPod podName ns ["bash", "-c", s!"exec 3<>/dev/tcp/localhost/12121; printf '{statsCmd}\\r\\n' >&3; timeout 3 bash -c 'while IFS= read -r line; do printf \"%s\\n\" \"$line\"; case \"$line\" in END*) break;; esac; done' <&3; exec 3>&-"]

/-- What a bounded stats probe (`timeout 3` inside the exec) says about a
    pod's data: `(hasData, knownEmpty)`. A pod lands in `knownEmpty` ONLY when
    the reply was complete (ended with END) and carried a well-formed
    `curr_items 0`. A pod that could not be read — no IP yet, exec or stats
    failure, truncated or malformed reply, or listed in `blocked` (test seam)
    — is in NEITHER list: Unknown is never emptiness (CI 37296281060). The
    caller binds `knownEmpty` to the pod incarnation it listed. -/
def dataPresencePodKeys (pods : List PodInfo) (ns : String) (alsoProbe : List String := [])
    (blocked : List String := []) : IO (List String × List String) := do
  let mut keys : List String := []
  let mut empty : List String := []
  for pod in pods do
    -- `alsoProbe`: node keys read even while NotReady. A returning ex-master
    -- stays NotReady in Prepare (sync-gated readiness) although its PVC
    -- holds the partition's newest copy; without reading it the refill took
    -- it for empty (failover-lag hold, 2026-10-03).
    if (pod.ready || pod.terminating || alsoProbe.contains pod.toNodeKey) && !blocked.contains pod.name then
      match ← queryPodStats pod.name ns "stats" with
      | .ok out =>
        let lines := out.splitOn "\n" |>.map (fun l => l.trim.replace "\r" "")
        let complete := lines.any (· == "END")
        let items : Option Nat := lines.findSome? fun line =>
          match (line.splitOn " ").filter (· != "") with
          | ["STAT", "curr_items", v] => v.toNat?
          | _ => none
        match items with
        | some n =>
          if n > 0 then keys := keys ++ [pod.toNodeKey]
          else if complete then empty := empty ++ [pod.toNodeKey]
        | none => pure ()
      | .error _ => pure ()
  return (keys, empty)

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

-- ===========================================================================
-- Cordon move (StateMachine/NodeMove.lean)
-- ===========================================================================

/-- Names of the Nodes with spec.unschedulable=true (cordoned). An error is
    NOT an empty list: nothing is decided from an unreadable node list. -/
def listCordonedNodes : IO (Except String (List String)) := do
  match ← kubectl ["get", "nodes", "-o",
      "jsonpath={range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{\"\\n\"}{end}"] with
  | .error e => return .error s!"list cordoned nodes: {e}"
  | .ok out => return .ok ((out.splitOn "\n").map (·.trim) |>.filter (· != ""))

/-- Wall clock in ms (the move's persisted times must survive a restart). -/
def wallMs : IO Nat := do
  let out ← IO.Process.output { cmd := "date", args := #["+%s%3N"] }
  return (out.stdout.trim.toNat?).getD 0

/-- `status.nodeMoves` as stored: the parsed ledger and the raw JSON (none =
    absent). The raw value is the CAS precondition of the next write. -/
def readNodeMoves (crName ns : String) : IO (Except String (NodeMove.Ledger × Option Lean.Json)) := do
  match ← kubectl ["get", "flarecluster", crName, "-n", ns, "-o", "json"] with
  | .error e => return .error s!"node moves read failed: {e}"
  | .ok out =>
    match Lean.Json.parse out with
    | .error e => return .error s!"node moves read: CR JSON did not parse: {e}"
    | .ok j =>
      match j.getObjVal? "status" >>= (·.getObjVal? "nodeMoves") with
      | .error _ => return .ok ({}, none)
      | .ok r =>
        match NodeMove.Ledger.fromJson? r with
        | some l => return .ok (l, some r)
        | none => return .error "node moves read: status.nodeMoves is present but does not parse (corrupt); refusing to start from an empty record"

/-- Compare-and-swap of `status.nodeMoves`: a JSON patch whose `test` holds
    the value this writer read (the stored value must still be exactly it) and
    whose `add` writes the new one. The operator's phase writes and the node
    guard's `admitted` write all go through here, so of two writers that read
    the same record at most one commits. A resourceVersion test would fail on
    every unrelated status write (handovers, repairs): this one only on a
    change of the nodeMoves record itself. -/
def casNodeMoves (crName ns : String) (old : Option Lean.Json) (new : NodeMove.Ledger)
    (timeoutSec : Nat := 30) : IO (Except String Unit) := do
  let ops : List Lean.Json :=
    (match old with
     | some o => [Lean.Json.mkObj [("op", "test"), ("path", "/status/nodeMoves"), ("value", o)]]
     | none => []) ++
    [Lean.Json.mkObj [("op", "add"), ("path", "/status/nodeMoves"), ("value", new.toJson)]]
  let patch := (Lean.Json.arr ops.toArray).compress
  let args := ["patch", "flarecluster", crName, "-n", ns, "--subresource=status", "--type=json", "-p", patch]
  -- bounded: a hung call must not outlast the caller's lease margin
  let out ← IO.Process.output { cmd := "timeout", args := #["-k", "1", toString timeoutSec, "kubectl"] ++ args.toArray }
  if out.exitCode == 0 then return .ok ()
  else if out.exitCode == 124 then return .error s!"node moves CAS timed out after {timeoutSec}s (outcome unknown; re-read)"
  else return .error s!"node moves CAS refused: {out.stderr.trim}"

/-- Put the serving label on / take it off a pod, only if it is still the
    pod with `uid`. Adding refuses a terminating pod: such a pod never gets
    the label back. -/
def setServingLabel (pod ns uid : String) (on : Bool) : IO (Except String Unit) := do
  if on then
    match ← kubectl ["get", "pod", pod, "-n", ns, "-o", "jsonpath={.metadata.deletionTimestamp}"] with
    | .error e => return .error e
    | .ok ts =>
      if !ts.trim.isEmpty then return .error s!"{pod} is terminating: the serving label is not put back"
  let key := "/metadata/labels/flare.gree.net~1serving"
  let ops : List Lean.Json :=
    [Lean.Json.mkObj [("op", "test"), ("path", "/metadata/uid"), ("value", Lean.Json.str uid)],
     if on then Lean.Json.mkObj [("op", "add"), ("path", key), ("value", "true")]
     else Lean.Json.mkObj [("op", "remove"), ("path", key)]]
  match ← kubectl ["patch", "pod", pod, "-n", ns, "--type=json", "-p", (Lean.Json.arr ops.toArray).compress] with
  | .ok _ => return .ok ()
  | .error e => return .error e

/-- Names of the pods the EndpointSlices of Service `svc` list (ready or
    not: any listing means the Service can still send to them). -/
def serviceEndpointPods (svc ns : String) : IO (Except String (List String)) := do
  match ← kubectl ["get", "endpointslices", "-n", ns, "-l", s!"kubernetes.io/service-name={svc}",
      "-o", "jsonpath={range .items[*].endpoints[*]}{.targetRef.name}{\"\\n\"}{end}"] with
  | .error e => return .error s!"endpointslices of {svc}: {e}"
  | .ok out => return .ok ((out.splitOn "\n").map (·.trim) |>.filter (· != ""))

/-- A Kubernetes Event on the FlareCluster (operator actions the user must
    see: a cordon move blocked below minCopies, held, released). -/
def emitEvent (crName ns reason message : String) (warning : Bool := false) : IO Unit := do
  let ms ← wallMs
  let name := s!"{crName}.{reason.toLower}.{ms}"
  let ev := Lean.Json.mkObj [
    ("apiVersion", "v1"), ("kind", "Event"),
    ("metadata", Lean.Json.mkObj [("name", Lean.Json.str name), ("namespace", Lean.Json.str ns)]),
    ("involvedObject", Lean.Json.mkObj [("apiVersion", "flare.gree.net/v1alpha1"), ("kind", "FlareCluster"),
      ("name", Lean.Json.str crName), ("namespace", Lean.Json.str ns)]),
    ("reason", Lean.Json.str reason), ("message", Lean.Json.str message),
    ("type", Lean.Json.str (if warning then "Warning" else "Normal")),
    ("source", Lean.Json.mkObj [("component", "flare-operator")])]
  match ← kubectlApplyManifest ev.compress with
  | .ok _ => pure ()
  | .error e => IO.eprintln s!"[flare-operator] warning: Event {reason} not recorded: {e}"

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
  /-- seconds since the last renewal, at the read -/
  ageSeconds : Nat := 0
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
                   transitions := transStr.trim.toNat?.getD 0, ageSeconds := age }
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
