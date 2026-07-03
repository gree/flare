/-
  Kubectl.lean - IO.Process kubectl bridge
  Following Gungnir/Main.lean subprocess pattern
-/

import FlareOperator.K8s.FlareCluster
import Lean.Data.Json

namespace FlareOperator.Kubectl

open FlareOperator.K8s

/-- Run kubectl with given arguments and return stdout or error. -/
def kubectl (args : List String) : IO (Except String String) := do
  try
    let result ← IO.Process.output { cmd := "kubectl", args := args.toArray }
    if result.exitCode == 0 then
      return .ok result.stdout
    else
      return .error s!"kubectl failed (exit {result.exitCode}): {result.stderr}"
  catch e =>
    return .error s!"kubectl error: {e}"

/-- Apply a manifest to the cluster by writing it to a temp file and running
    `kubectl apply -f <file>` (argv-direct, no shell).

    This exists so that untrusted data (node names, CRD-supplied config values)
    embedded in the manifest is never interpolated into a `sh -c` string. Building
    a shell command with such data (`kubectl create ... --from-literal=x='{data}'`)
    is a command-injection vector: a node registering as `x';kubectl delete ns …;'`
    would break out of the quoting and run arbitrary commands with the operator's
    ClusterRole.

    We route the manifest through a temp file rather than stdin: Lean's
    `IO.FS.Handle` has no explicit close and piping to `kubectl apply -f -` risks
    a deadlock (the child blocks on stdin EOF while we block on its stdout). A temp
    file sidesteps that entirely and is still shell-free. The file is unlinked in
    a `finally`-style cleanup regardless of the apply result. -/
def kubectlApplyManifest (manifest : String) : IO (Except String String) := do
  try
    -- Unique-per-call temp path (pid + monotonic clock) to avoid collisions
    -- between concurrent operator goroutines / reconcile ticks.
    let pid ← IO.Process.getPID
    let nowNs ← IO.monoNanosNow
    let tmpPath : System.FilePath := s!"/tmp/flare-operator-manifest-{pid}-{nowNs}.yaml"
    IO.FS.writeFile tmpPath manifest
    let result ← IO.Process.output {
      cmd := "kubectl"
      args := #["apply", "-f", tmpPath.toString]
    }
    -- Best-effort cleanup; ignore errors (e.g. already gone).
    try IO.FS.removeFile tmpPath catch _ => pure ()
    if result.exitCode == 0 then
      return .ok result.stdout
    else
      return .error s!"kubectl apply failed (exit {result.exitCode}): {result.stderr}"
  catch e =>
    return .error s!"kubectl apply error: {e}"

/-- Parse a FlareClusterView from a Lean.Json object. -/
private def getFlareClusterFromJson (json : Lean.Json) (name ns : String)
    : Except String FlareClusterView := do
  let spec ← json.getObjVal? "spec"
  let partitions := spec.getObjValD "partitions" |>.getNat?.toOption |>.getD 1
  let replicas := spec.getObjValD "replicas" |>.getNat?.toOption |>.getD 1
  let replObj := spec.getObjValD "clusterReplication"
  let repl : ClusterReplicationSpec := {
    enabled := replObj.getObjValD "enabled" |>.getBool?.toOption |>.getD false
    serverName := replObj.getObjValD "serverName" |>.getStr?.toOption |>.getD ""
    port := replObj.getObjValD "port" |>.getNat?.toOption |>.getD 12121
    mode := replObj.getObjValD "mode" |>.getStr?.toOption |>.getD "duplicate"
    concurrency := replObj.getObjValD "concurrency" |>.getNat?.toOption |>.getD 2
  }
  let rocksdbObj := spec.getObjValD "rocksdb"
  let rocksdb : RocksdbConfigSpec := {
    walTtlSeconds := rocksdbObj.getObjValD "walTtlSeconds" |>.getNat?.toOption
    walSizeLimitMb := rocksdbObj.getObjValD "walSizeLimitMb" |>.getNat?.toOption
    syncWrites := rocksdbObj.getObjValD "syncWrites" |>.getBool?.toOption
    resyncFailureThreshold := rocksdbObj.getObjValD "resyncFailureThreshold" |>.getNat?.toOption
    walMaxBatchBytes := rocksdbObj.getObjValD "walMaxBatchBytes" |>.getNat?.toOption
    walSyncBwlimit := rocksdbObj.getObjValD "walSyncBwlimit" |>.getNat?.toOption
    walSyncInterval := rocksdbObj.getObjValD "walSyncInterval" |>.getNat?.toOption
  }
  .ok {
    metadata := { name := some name, «namespace» := some ns }
    spec := {
      partitions := partitions, replicas := replicas,
      clusterReplication := repl, rocksdb := rocksdb
    }
  }

/-- Get a FlareCluster CR by name and namespace. Returns a minimal view. -/
def getFlareCluster (name ns : String) : IO (Except String FlareClusterView) := do
  let result ← kubectl ["get", "flarecluster", name, "-n", ns, "-o", "json"]
  match result with
  | .error e => return .error e
  | .ok output =>
    match Lean.Json.parse output with
    | .error e => return .error s!"JSON parse error: {e}"
    | .ok json => return getFlareClusterFromJson json name ns

/-- List flared pods matching a label selector. Returns (podName, podIP, port). -/
def listFlaredPods (crName ns : String) : IO (List (String × String × Nat)) := do
  let result ← kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={crName}",
                         "-o", "jsonpath={range .items[*]}{.metadata.name} {.status.podIP} 12121{\"\\n\"}{end}"]
  match result with
  | .error _ => return []
  | .ok output =>
    let lines := output.splitOn "\n" |>.filter (· != "")
    return lines.filterMap fun line =>
      let parts := line.splitOn " "
      match parts with
      | [podName, ip, portStr] =>
        match portStr.trim.toNat? with
        | some port => some (podName, ip, port)
        | none => none
      | _ => none

/-- Patch a Service selector to point to a specific pod. -/
def patchServiceSelector (svcName ns podName : String) : IO (Except String Unit) := do
  let patch := s!"\{\"spec\":\{\"selector\":\{\"statefulset.kubernetes.io/pod-name\":\"{podName}\"}}}"
  let result ← kubectl ["patch", "svc", svcName, "-n", ns, "-p", patch]
  match result with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- List all FlareCluster CRs in a namespace. Returns (name, namespace). -/
def listFlareClusters (ns : String) : IO (Except String (List (String × String))) := do
  let result ← kubectl ["get", "flarecluster", "-n", ns,
                         "-o", "jsonpath={range .items[*]}{.metadata.name} {.metadata.namespace}{\"\\n\"}{end}"]
  match result with
  | .error e => return .error e
  | .ok output =>
    let lines := output.splitOn "\n" |>.filter (· != "")
    let pairs := lines.filterMap fun line =>
      let parts := line.splitOn " "
      match parts with
      | [crName, crNs] => some (crName.trim, crNs.trim)
      | _ => none
    return .ok pairs

end FlareOperator.Kubectl
