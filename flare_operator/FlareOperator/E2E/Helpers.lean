/-
  E2E/Helpers.lean - K8s + protocol helpers for E2E tests

  Reuses FlareOperator.Kubectl.kubectl for all kubectl calls.
  Provides higher-level helpers for waiting, TCP commands, and memcached operations.
-/

import FlareOperator.Kubectl

namespace FlareOperator.E2E.Helpers

open FlareOperator.Kubectl

-- ===========================================================================
-- kubectl helpers
-- ===========================================================================

/-- Apply YAML from stdin via kubectl. -/
def kubectlApplyStdin (yaml : String) : IO (Except String String) := do
  try
    let result ← IO.Process.output {
      cmd := "sh"
      args := #["-c", s!"echo '{yaml}' | kubectl apply -f -"]
    }
    if result.exitCode == 0 then
      return .ok result.stdout
    else
      return .error s!"kubectl apply failed (exit {result.exitCode}): {result.stderr}"
  catch e =>
    return .error s!"kubectl apply error: {e}"

/-- Delete a K8s resource by name, ignoring not-found errors. -/
def kubectlDelete (resource : String) (name ns : String) : IO Unit := do
  let _ ← kubectl ["delete", resource, name, "-n", ns, "--ignore-not-found"]

/-- Patch a K8s resource with JSON merge patch. -/
def kubectlPatch (resource name ns patchJson : String) : IO (Except String String) :=
  kubectl ["patch", resource, name, "-n", ns, "--type=merge", "-p", patchJson]

/-- Wait for a resource to be ready using kubectl wait. -/
def kubectlWaitReady (resource ns : String) (timeoutSec : Nat) : IO Bool := do
  match ← kubectl ["wait", "--for=condition=Ready", resource, "-n", ns,
                    s!"--timeout={timeoutSec}s"] with
  | .ok _ => return true
  | .error _ => return false

/-- Wait for rollout status of a resource. -/
def kubectlRolloutStatus (resource ns : String) (timeoutSec : Nat) : IO Bool := do
  match ← kubectl ["rollout", "status", resource, "-n", ns,
                    s!"--timeout={timeoutSec}s"] with
  | .ok _ => return true
  | .error _ => return false

/-- Get a jsonpath value from a K8s resource. -/
def kubectlGetJsonpath (resource name ns jsonpath : String) : IO (Except String String) := do
  let result ← kubectl ["get", resource, name, "-n", ns, "-o", s!"jsonpath={jsonpath}"]
  match result with
  | .ok output => return .ok output.trim
  | .error e => return .error e

/-- Scale a resource to a given number of replicas. -/
def kubectlScale (resource name ns : String) (replicas : Nat) : IO (Except String String) :=
  kubectl ["scale", resource, name, "-n", ns, s!"--replicas={replicas}"]

/-- Get recent logs from a pod. -/
def kubectlLogs (podName ns : String) (tail : Nat) : IO String := do
  match ← kubectl ["logs", podName, "-n", ns, s!"--tail={tail}"] with
  | .ok output => return output
  | .error _ => return ""

/-- Get logs from pods matching a label selector. -/
def kubectlLogsLabel (label ns : String) (tail : Nat) : IO String := do
  match ← kubectl ["logs", "-l", label, "-n", ns, s!"--tail={tail}"] with
  | .ok output => return output
  | .error _ => return ""

-- ===========================================================================
-- Polling
-- ===========================================================================

/-- Wait for a condition, polling every 5s. Returns true if condition met. -/
def waitForCondition (desc : String) (timeoutSec : Nat) (check : IO Bool) : IO Bool := do
  IO.eprintln s!"# Waiting for: {desc} (timeout: {timeoutSec}s)"
  let rec loop (elapsed : Nat) (fuel : Nat) : IO Bool := do
    match fuel with
    | 0 => return false
    | fuel + 1 =>
      if elapsed >= timeoutSec then
        IO.eprintln s!"#   TIMEOUT after {timeoutSec}s waiting for: {desc}"
        return false
      let ok ← try check catch _ => pure false
      if ok then
        IO.eprintln s!"#   OK after {elapsed}s"
        return true
      IO.sleep 5000
      loop (elapsed + 5) fuel
  loop 0 (timeoutSec / 5 + 1)

-- ===========================================================================
-- String helpers
-- ===========================================================================

/-- Check if needle is a substring of haystack. -/
def containsSubstr (haystack needle : String) : Bool :=
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
-- TCP/protocol helpers (via kubectl exec in debug pod)
-- ===========================================================================

/-- Execute a command in the debug pod. -/
def execInDebugPod (debugPod ns cmd : String) : IO (Except String String) := do
  kubectl ["exec", debugPod, "-n", ns, "--", "sh", "-c", cmd]

/-- Send a TCP command to the operator via the debug pod. -/
def operatorTcpCmd (debugPod ns operatorSvc : String) (port : Nat) (cmd : String) : IO String := do
  let shellCmd := s!"printf '%s\\r\\n' '{cmd}' | nc -w 3 {operatorSvc}.{ns}.svc.cluster.local {port}"
  match ← execInDebugPod debugPod ns shellCmd with
  | .ok output => return output
  | .error e => return s!"ERROR: {e}"

/-- Set a key in memcached via the debug pod. -/
def memcachedSet (debugPod ns targetIp : String) (port : Nat) (key value : String) : IO Bool := do
  let len := value.length
  let cmd := s!"printf 'set {key} 0 0 {len}\\r\\n{value}\\r\\n' | nc -w 3 {targetIp} {port}"
  match ← execInDebugPod debugPod ns cmd with
  | .ok output => return (containsSubstr output "STORED")
  | .error _ => return false

/-- Get a key from memcached via the debug pod. -/
def memcachedGet (debugPod ns targetIp : String) (port : Nat) (key : String) : IO (Option String) := do
  let cmd := s!"printf 'get {key}\\r\\n' | nc -w 3 {targetIp} {port}"
  match ← execInDebugPod debugPod ns cmd with
  | .ok output =>
    let lines := output.splitOn "\n" |>.map String.trim |>.filter (· != "")
    -- memcached GET response: VALUE <key> <flags> <len>\r\n<data>\r\n
    match lines with
    | _ :: dataLine :: _ =>
      let cleaned := dataLine.trim.replace "\r" ""
      if cleaned == "END" then return none
      else return some cleaned
    | _ => return none
  | .error _ => return none

/-- Get curr_items from memcached stats. -/
def getCurrItems (debugPod ns targetIp : String) (port : Nat) : IO Nat := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {targetIp} {port}"
  match ← execInDebugPod debugPod ns cmd with
  | .ok output =>
    let lines := output.splitOn "\n"
    for line in lines do
      let trimmed := line.trim
      if trimmed.startsWith "STAT curr_items " then
        let parts := trimmed.splitOn " "
        match parts with
        | [_, _, val] => return val.trim.replace "\r" "" |>.toNat?.getD 0
        | _ => pure ()
    return 0
  | .error _ => return 0

-- ===========================================================================
-- Node sync parsing
-- ===========================================================================

/-- Parsed entry from a NODE SYNC response. -/
structure NodeSyncEntry where
  fqdn : String
  port : Nat
  role : Nat
  state : Nat
  partition : Int
  balance : Nat
  deriving Repr

instance : BEq NodeSyncEntry where
  beq a b := a.fqdn == b.fqdn && a.port == b.port

/-- Parse a single NODE line: "NODE <fqdn> <port> <role> <state> <partition> <balance> <thread>" -/
private def parseNodeLine (line : String) : Option NodeSyncEntry :=
  let parts := line.trim.splitOn " " |>.filter (· != "")
  match parts with
  | "NODE" :: fqdn :: portStr :: roleStr :: stateStr :: partStr :: balStr :: _ =>
    match portStr.toNat?, roleStr.toNat?, stateStr.toNat?, partStr.toInt?, balStr.toNat? with
    | some port, some role, some state, some part, some bal =>
      some { fqdn := fqdn, port := port, role := role, state := state,
             partition := part, balance := bal }
    | _, _, _, _, _ => none
  | _ => none

/-- Parse a full NODE SYNC response into entries. -/
def parseNodeSync (raw : String) : List NodeSyncEntry :=
  let lines := raw.splitOn "\n" |>.map (·.replace "\r" "")
  lines.filterMap parseNodeLine

/-- Find the FQDN of the master pod for a given partition. -/
def findMasterFqdn (entries : List NodeSyncEntry) (partition : Nat) : Option String :=
  entries.find? (fun e => e.role == 0 && e.state == 0 && e.partition == Int.ofNat partition)
    |>.map (·.fqdn)

/-- Find the pod name (first component of FQDN) of the master for a partition. -/
def findMasterPod (entries : List NodeSyncEntry) (partition : Nat) : Option String :=
  match findMasterFqdn entries partition with
  | some fqdn => some ((fqdn.splitOn ".").headD fqdn)
  | none => none

/-- Count total masters across all partitions. -/
def countMasters (entries : List NodeSyncEntry) : Nat :=
  (entries.filter (fun e => e.role == 0 && e.state == 0)).length

/-- Count active nodes (not Down, state != 2). -/
def countActiveNodes (entries : List NodeSyncEntry) : Nat :=
  (entries.filter (fun e => e.state != 2)).length

/-- Check one-master-per-partition invariant. Returns list of partition indices with duplicates. -/
def checkOneMasterPerPartition (entries : List NodeSyncEntry) : List Int :=
  let masters := entries.filter (fun e => e.role == 0 && e.state == 0)
  let partitions := masters.map (·.partition)
  -- Find duplicates
  partitions.filter (fun p => (partitions.filter (· == p)).length > 1)
    |>.eraseDups

/-- Get pod IP via kubectl. -/
def getPodIp (podName ns : String) : IO (Option String) := do
  match ← kubectlGetJsonpath "pod" podName ns "{.status.podIP}" with
  | .ok ip => if ip.trim == "" then return none else return some ip.trim
  | .error _ => return none

/-- Get pod IPs for pods matching a label selector. -/
def getPodIps (label ns : String) : IO (List String) := do
  match ← kubectl ["get", "pods", "-n", ns, "-l", label,
                    "-o", "jsonpath={range .items[*]}{.status.podIP}{\"\\n\"}{end}"] with
  | .ok output =>
    return output.splitOn "\n" |>.map String.trim |>.filter (· != "")
  | .error _ => return []

/-- Get pod names for pods matching a label selector. -/
def getPodNames (label ns : String) : IO (List String) := do
  match ← kubectl ["get", "pods", "-n", ns, "-l", label,
                    "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"] with
  | .ok output =>
    return output.splitOn "\n" |>.map String.trim |>.filter (· != "")
  | .error _ => return []

end FlareOperator.E2E.Helpers
