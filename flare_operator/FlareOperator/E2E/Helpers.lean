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

/-- Copy retention (§9): the rebuild reserve E2E clusters run with. Unset,
    every staged rebuild stops (rebuild_blocked=reserve_unset). -/
def e2eRebuildReserveBytes : Nat := 67108864

/-- A FlareCluster patch that sets `spec.rocksdb` makes the operator rewrite
    extra.conf from the CR alone, so the reserve baked into the boot-time
    extra.conf would be gone at the next pod start: such a patch carries the
    reserve too, unless it sets one itself. -/
def withRebuildReserve (resource patchJson : String) : String :=
  let has := fun (n : String) => (patchJson.splitOn n).length > 1
  if resource != "flarecluster" || has "rebuildReserveBytes" then patchJson
  else if has "\"rocksdb\":{}" then
    patchJson.replace "\"rocksdb\":{}" s!"\"rocksdb\":\{\"rebuildReserveBytes\":{e2eRebuildReserveBytes}}"
  else if has "\"rocksdb\":{" then
    patchJson.replace "\"rocksdb\":{" s!"\"rocksdb\":\{\"rebuildReserveBytes\":{e2eRebuildReserveBytes},"
  else patchJson

/-- Patch a K8s resource with JSON merge patch. -/
def kubectlPatch (resource name ns patchJson : String) : IO (Except String String) :=
  kubectl ["patch", resource, name, "-n", ns, "--type=merge", "-p", withRebuildReserve resource patchJson]

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

/-- One decision of `waitForCondition`, pure (unit tested). Times are
    monotonic milliseconds. A check is only STARTED before the deadline; a
    check that holds only AFTER the deadline is `late`, which the wait
    reports as a timeout (not a success). -/
inductive WaitStep where
  | ok | late | timeout | again
  deriving Repr, BEq

/-- Before a check: may it start? -/
def mayStartCheck (now deadline : Nat) : Bool := now < deadline

/-- After a check that ended at `ended`. -/
def waitStep (ok : Bool) (ended deadline : Nat) : WaitStep :=
  if ok then (if ended ≤ deadline then .ok else .late)
  else if ended ≥ deadline then .timeout else .again

/-- Wait until `check` holds, for at most `timeoutSec` seconds of REAL
    (monotonic) time (CI 37731207056: the elapsed time used to count only the
    5 s sleeps, so slow checks stretched a "300 s" wait far beyond 300 s).
    A check is started only before the deadline, and a check that holds only
    after it counts as a TIMEOUT (logged as late) — so an OK is a success
    within the limit. The call can still return up to one check's duration
    after the deadline: a check is bounded only by the subprocess timeouts it
    uses itself (every `kubectl` call: 30 s + 5 s kill; a check calling an
    unbounded subprocess can overrun by that much). Each check slower than
    10 s, and on a timeout the last kubectl failure seen during the wait, are
    logged — to tell "the condition never held" from "it could not be
    observed". -/
def waitForCondition (desc : String) (timeoutSec : Nat) (check : IO Bool) : IO Bool := do
  IO.eprintln s!"# Waiting for: {desc} (timeout: {timeoutSec}s)"
  let start ← IO.monoMsNow
  let deadline := start + timeoutSec * 1000
  let (seq0, _) ← FlareOperator.Kubectl.lastKubectlFailure.get
  let mut checks := 0
  let mut slowest := 0
  let timeoutLine := fun (now checks slowest : Nat) (extra : String) => do
    let (seq, last) ← FlareOperator.Kubectl.lastKubectlFailure.get
    IO.eprintln s!"#   TIMEOUT after {(now - start) / 1000}s (limit {timeoutSec}s; {checks} check(s), slowest {slowest / 1000}s){extra} waiting for: {desc}{if seq != seq0 then s!"; last kubectl failure during the wait: {last}" else "; no kubectl failure during the wait"}"
  repeat
    let t0 ← IO.monoMsNow
    if !mayStartCheck t0 deadline then
      timeoutLine t0 checks slowest ""
      return false
    let ok ← try check catch _ => pure false
    let t1 ← IO.monoMsNow
    checks := checks + 1
    let dur := t1 - t0
    if dur > slowest then slowest := dur
    if dur > 10000 then
      let (seq, last) ← FlareOperator.Kubectl.lastKubectlFailure.get
      IO.eprintln s!"#   slow check #{checks}: {dur / 1000}s{if seq != seq0 then s!" (last kubectl failure: {last})" else ""}"
    match waitStep ok t1 deadline with
    | .ok =>
      IO.eprintln s!"#   OK after {(t1 - start) / 1000}s"
      return true
    | .late =>
      timeoutLine t1 checks slowest s!"; the condition held only at {(t1 - start) / 1000}s, AFTER the limit (late, not a success)"
      return false
    | .timeout =>
      timeoutLine t1 checks slowest ""
      return false
    | .again => IO.sleep 5000
  return false

-- ===========================================================================
-- String helpers
-- ===========================================================================

/-- Check if needle is a substring of haystack. Compares bytes in place
    (`String.substrEq`) at each character position: O(n·m) without copying.
    The previous version took `haystack.drop i` at every position — a copy
    of the rest of the string each time, quadratic in the log size — and a
    growing flared log made each wait check slower (CI 37740298550
    copy-protection: checks of 11, 17, 27, 46, 88, 196 s). -/
def containsSubstr (haystack needle : String) : Bool :=
  let nb := needle.endPos.byteIdx
  let hb := haystack.endPos.byteIdx
  if nb == 0 then true
  else if nb > hb then false
  else
    let rec go (p : String.Pos) (fuel : Nat) : Bool :=
      match fuel with
      | 0 => false
      | fuel + 1 =>
        if p.byteIdx + nb > hb then false
        else if haystack.substrEq p needle 0 nb then true
        else go (haystack.next p) fuel
    go 0 (hb + 1)

-- ===========================================================================
-- TCP/protocol helpers (via kubectl exec in debug pod)
-- ===========================================================================

/-- The COMPLETE logs of every pod in `ns` (all containers, timestamps, the
    previous container too) into $FLARE_E2E_LOG_DIR/<ns>/ — uploaded with the
    CI results. The printed tails below lost the decisive windows (CI 28761ff:
    history (5)'s 240 s, authority 29's adoption). No-op without the variable. -/
def saveFullLogs (ns : String) : IO Unit := do
  let some root ← IO.getEnv "FLARE_E2E_LOG_DIR" | return
  let dir := s!"{root}/{ns}"
  discard <| IO.Process.output { cmd := "mkdir", args := #["-p", dir] }
  let pods ← match ← kubectl ["get", "pods", "-n", ns, "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"] with
    | .ok o => pure ((o.splitOn "\n").map String.trim |>.filter (!·.isEmpty))
    | .error _ => pure []
  for pod in pods do
    for (suffix, extra) in [("", ([] : List String)), (".previous", ["--previous"])] do
      match ← kubectl (["logs", "-n", ns, pod, "--all-containers", "--timestamps", "--tail=-1"] ++ extra) with
      | .ok out => if !out.isEmpty then IO.FS.writeFile s!"{dir}/{pod}{suffix}.log" out
      | .error _ => pure ()
  IO.eprintln s!"# full logs of {pods.length} pod(s) in {ns} saved under {dir}"

/-- Dump the suite's operator + flared logs (call from TestSuite.onFailure:
    per-suite operators are deleted in teardown, so the CI end-of-run dump
    can never capture the failing suite's logs — this hook point can). -/
def dumpClusterDiagnostics (ns : String) (operatorLabel : String := "app=flare-operator") : IO Unit := do
  saveFullLogs ns
  -- NOTE: suites with a custom operatorName MUST pass their own label
  -- (s!"app={cfg.operatorName}") — the default matches nothing there and the
  -- operator-log block comes back silently empty (bit us on a real failure).
  IO.eprintln s!"# === operator logs ({ns}, {operatorLabel}) ==="
  match ← kubectl ["logs", "-n", ns, "-l", operatorLabel, "--tail=200", "--prefix"] with
  | .ok out => for line in out.splitOn "\n" do IO.eprintln s!"# {line}"
  | .error e => IO.eprintln s!"# (operator logs unavailable: {e})"
  IO.eprintln s!"# === flared logs ({ns}, tail 80 each) ==="
  match ← kubectl ["logs", "-n", ns, "-l", "app=flare", "--tail=80", "--prefix"] with
  | .ok out => for line in out.splitOn "\n" do IO.eprintln s!"# {line}"
  | .error e => IO.eprintln s!"# (flared logs unavailable: {e})"
  -- Pod-level timeline: readiness-probe outcomes (incl. the probe script's
  -- output in Unhealthy events), scheduling/start times, restart counts.
  -- This is the only place the "was the pod Ready, and if not why" question
  -- is answerable after the fact — the node map alone can't distinguish a
  -- NotReady pod from an unrecreated one.
  IO.eprintln s!"# === pods ({ns}) ==="
  match ← kubectl ["get", "pods", "-n", ns, "-o", "wide"] with
  | .ok out => for line in out.splitOn "\n" do IO.eprintln s!"# {line}"
  | .error e => IO.eprintln s!"# (pods unavailable: {e})"
  IO.eprintln s!"# === events ({ns}, by time) ==="
  match ← kubectl ["get", "events", "-n", ns, "--sort-by=.lastTimestamp"] with
  | .ok out => for line in out.splitOn "\n" do IO.eprintln s!"# {line}"
  | .error e => IO.eprintln s!"# (events unavailable: {e})"
  IO.eprintln s!"# === describe flared pods ({ns}) ==="
  match ← kubectl ["describe", "pods", "-n", ns, "-l", "app=flare"] with
  | .ok out => for line in out.splitOn "\n" do IO.eprintln s!"# {line}"
  | .error e => IO.eprintln s!"# (describe unavailable: {e})"

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
    -- An explicit error is NOT a miss (read-unavailable-error answers
    -- SERVER_ERROR when a get cannot be served). This helper's callers only
    -- see "no value", so make the difference visible in the log; tests that
    -- must tell them apart use TraceMatch.parseGetReplies.
    if lines.any (fun l => l.startsWith "SERVER_ERROR" || l.startsWith "CLIENT_ERROR" || l.startsWith "ERROR") then
      IO.eprintln s!"# memcachedGet {key} on {targetIp}: EXPLICIT ERROR (not a miss): {lines.head?.getD ""}"
      return none
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

-- ===========================================================================
-- Key writing helper
-- ===========================================================================

/-- Write N keys via a single memcached entry point (proxy routing distributes).
    Returns the number of successfully stored keys. -/
def writeKeys (debugPod ns targetIp : String) (port : Nat) (keyPrefix : String) (count : Nat)
    : IO Nat := do
  let mut stored := 0
  for i in List.range count do
    let ok ← memcachedSet debugPod ns targetIp port s!"{keyPrefix}_{i}" s!"val_{i}"
    if ok then stored := stored + 1
  return stored

-- ===========================================================================
-- Partition-aware item counting
-- ===========================================================================

/-- Get curr_items from the master of a specific partition.
    Queries the operator for NODE SYNC, finds the master pod for the partition,
    gets its IP, then queries memcached stats. -/
def getPartitionMasterItems (debugPod ns operatorName : String) (operatorPort : Nat)
    (partition : Nat) (flarePort : Nat) : IO Nat := do
  let sync ← operatorTcpCmd debugPod ns operatorName operatorPort "node sync"
  let entries := parseNodeSync sync
  match findMasterPod entries partition with
  | none => return 0
  | some masterPod =>
    match ← getPodIp masterPod ns with
    | none => return 0
    | some ip => getCurrItems debugPod ns ip flarePort

/-- Get total curr_items across all pods matching a label selector. -/
def getTotalItems (debugPod ns label : String) (flarePort : Nat) : IO Nat := do
  let ips ← getPodIps label ns
  let mut total := 0
  for ip in ips do
    let items ← getCurrItems debugPod ns ip flarePort
    total := total + items
  return total

end FlareOperator.E2E.Helpers
