/-
  E2E/Tests/TopologyAuthority.lean — SAF-01 / SC-01.

  "Only the current leader may issue topology changes; recipients must
  reject obsolete authority."

  Two halves, tested separately because they fail differently:

  RECIPIENT. flared fences on node_map_version monotonicity
  (cluster::reconstruct_node ignores a map whose version is not newer). The
  first test pushes a MUTATED map at a stale version straight at a flared
  pod, using the operator's own wire client, and asserts the map is not
  adopted. It also asserts flared LOGGED the rejection — without that the
  test would pass just as happily if the push never arrived, which is the
  usual way a negative test rots.

  This fencing is the real bound on a stale leader, and it is bounded in
  turn: it only protects a recipient that has ALREADY observed the newer
  version. A pod that missed the new leader's broadcast has nothing to
  compare against and will accept the old leader's map. That limit is the
  reason SC-01 also requires the sender-side check below.

  SENDER. The remaining tests drive ONE production reconcile pass to a
  named stop position — after the commit, before the pre-send lease check
  (preSendBarrier in Main.lean, inert without FLARE_TEST_PRESEND_BARRIER) —
  prove the position was reached by the version the operator writes there,
  change the lease while the pass is held, and then judge the branch that
  pass takes when released:
    * control (lease kept): the pass broadcasts that version;
    * lease taken by another identity: fence log for that version, no
      send, the process exits (the restart count moves), the restarted
      leader re-acquires and re-applies the topology;
    * lease unreadable: read-failure branch, no send, and the withheld
      map is published by a later pass of the same process that names the
      suppressed version.
  A receiver whose version does not move is never accepted as evidence on
  its own: a crash, a timeout, or an exit before the check look the same.

  SAME-NAME REPLACEMENT (SAF-08). The topology audit brackets each stats
  reply with two Pod UID reads. A test seam (FLARE_TEST_PROBE_BARRIER) holds
  the probe of one pod after its first UID read; the test replaces that pod
  under the same name, releases the probe, and requires the reply to be
  judged Unknown, then requires a later probe to observe the new pod as
  current (Unknown clears by fresh evidence, it does not stick).

  STARTUP REPUBLISH (SAF-09). The last test holds a committed pass before
  its send and replaces the operator while it is held, so the map is
  persisted and never sent. The fresh process seeds its pending flag with
  the committed version on startup; that seed must deliver the map on its
  own. Two other things could also send and would hide a missing seed: a
  version change in the first pass, and the topology audit marking a behind
  pod as pending. The test turns the audit off (FLARE_TEST_TOPOLOGY_AUDIT_OFF,
  a test-only seam) and requires the first send's logged trigger record to
  be pending-only, then requires every pod to adopt the withheld read-balance
  weight, not just the version. The takeover test above does not show this:
  its final check accepts any map that names the same master, which the old
  map already did.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.TopologyAuthority

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl
open FlareOperator.K8s

/-- Directory inside the operator container that drives the pre-send
    barrier. See preSendBarrier in Main.lean. -/
private def barrierDir : String := "/tmp/saf01"

private def cfg : ClusterConfig := {
  name := "topo-auth"
  «namespace» := "flare-topo-auth"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-topo-auth"
  operatorEnv := [("FLARE_TEST_PRESEND_BARRIER", barrierDir), ("FLARE_TEST_PROBE_BARRIER", barrierDir)]
}

private def numPods : Nat := cfg.partitions * cfg.replicas

private def nodeView : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return parseNodeSync sync

/-- One numeric `stats` value straight from a flared pod. -/
private def flaredStat (targetIp key : String) : IO (Option Nat) := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {targetIp} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .error _ => return none
  | .ok output =>
    for line in output.splitOn "\n" do
      let t := (line.trim.replace "\r" "")
      if t.startsWith s!"STAT {key} " then
        match (t.splitOn " ").filter (· != "") with
        | [_, _, v] => return v.toNat?
        | _ => pure ()
    return none

/-- flared's own view of the topology, as a comparable signature. -/
private def flaredRoles (targetIp : String) : IO (List String) := do
  let cmd := s!"printf 'stats nodes\\r\\n' | nc -w 3 {targetIp} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .error _ => return []
  | .ok output =>
    return (output.splitOn "\n").filterMap (fun line =>
      let t := (line.trim.replace "\r" "")
      if t.startsWith "STAT " && (t.splitOn ":role").length > 1 then some t else none)
      |>.mergeSort (· ≤ ·)

/-- The node-sync payload the operator would send, with one Slave flipped
    to Master — a change flared would visibly adopt if it accepted the push.

    Sent from the DEBUG POD, not from this process: the E2E binary runs on
    the host and kind pod IPs are not routable from there. Calling the
    operator's own Lean client here looked tidier and silently pushed
    nothing; the first run caught that only because this test also asserts
    flared logged a rejection. -/
private def mutatedSyncPayload (entries : List NodeSyncEntry) (version : Nat) : String :=
  let step : (Bool × List String) → NodeSyncEntry → (Bool × List String) :=
    fun (flipped, acc) e =>
      let promote := e.role == 1 && !flipped
      let role := if promote then 0 else e.role
      (flipped || promote,
       acc ++ [s!"NODE {e.fqdn} {e.port} {role} {e.state} {e.partition} 100 16"])
  let lines := (entries.foldl step (false, [])).2
  s!"node sync {version}\\r\\n" ++ String.join (lines.map (· ++ "\\r\\n")) ++ "END\\r\\n"

/-- Restart count of the operator container, or none if the pod is not there.
    Losing the lease is DESIGNED to end the process, so the takeover test
    asserts that the restart happened rather than mistaking it for noise —
    and, conversely, would have caught the zombie that logged "exiting" and
    kept running. -/
private def operatorRestarts : IO (Option Nat) := do
  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}",
                   "-o", "jsonpath={.items[0].status.containerStatuses[0].restartCount}"] with
  | .ok out => return out.trim.toNat?
  | .error _ => return none

/-- The operator's log across the exit that losing the lease is designed to
    cause. `kubectl logs` shows the CURRENT container only; once kubelet has
    restarted the container the fence line lives in the previous one and a
    single read after a fixed sleep misses it (CI run 34799233967: the
    container was restarted within 8s, the fence line was gone, and the test
    reported "never reported the fence" although the fence had happened —
    the restarted container resumed at exactly the fenced version). Poll
    from the release, reading the previous container's log as well once the
    restart count moved, until the fence for the held version is seen or the
    window closes. -/
private def fenceEvidence (held restarts0 : Nat) (windowSec : Nat := 60) : IO String := do
  let label := s!"app={cfg.operatorName}"
  let mut acc := ""
  let mut elapsed := 0
  while elapsed < windowSec do
    let cur ← kubectlLogsLabel label cfg.«namespace» 400
    let prev ← do
      if ((← operatorRestarts).getD 0) > restarts0 then
        match ← kubectl ["logs", "-l", label, "-n", cfg.«namespace», "--previous", "--tail=400"] with
        | .ok out => pure out
        | .error _ => pure ""
      else pure ""
    acc := acc ++ "\n" ++ prev ++ "\n" ++ cur
    if containsSubstr acc s!"→ v{held})" then break
    IO.sleep 2000
    elapsed := elapsed + 2
  return acc

/-- Did the HELD pass itself broadcast `held`? The held pass is stopped past
    the version gate, so its send would log `topology changed (vOLD → vHELD),
    broadcasting` with OLD < HELD. A later pass that re-sends or retries the
    same committed map logs `(vHELD → vHELD), broadcasting` — legitimate, and
    in the read-failure test REQUIRED (the retry). The plain substring
    `→ vHELD), broadcasting` cannot tell the two apart; CI run 34802942000
    failed on exactly that: the fence was logged, the retry happened within
    the 8s window, and the retry's own line was read as the held pass
    sending. -/
private def heldPassBroadcast (log : String) (held : Nat) : Bool :=
  (log.splitOn "\n").any fun line =>
    containsSubstr line s!"→ v{held}), broadcasting" && !containsSubstr line s!"(v{held} → v{held})"

/-- Run a shell command inside the operator pod. -/
private def opExec (cmd : String) : IO (Except String String) := do
  let pods ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
  match pods.head? with
  | none => return .error "no operator pod"
  | some pod => kubectl ["exec", "-n", cfg.«namespace», pod, "--", "sh", "-c", cmd]

/-- Arm the barrier so the NEXT pass that gets past the version gate stops
    before the lease check. One-shot: the operator removes the arm file. -/
private def armBarrier : IO (Except String String) :=
  opExec s!"mkdir -p {barrierDir} && rm -f {barrierDir}/reached {barrierDir}/release && touch {barrierDir}/arm"

/-- The version of the pass that is currently held at the barrier, if any.
    Its presence is the test's proof that the stop position was reached —
    not that time passed, not that the process was busy. -/
private def barrierHeldVersion : IO (Option Nat) := do
  match ← opExec s!"cat {barrierDir}/reached 2>/dev/null || true" with
  | .error _ => return none
  | .ok out => return (out.trim.splitOn "\n").head?.bind (·.trim.toNat?)

/-- Release a pass that is being held, and wait until the operator has
    consumed the release.

    Releasing and clearing in one step is a race the operator loses: it
    polls for `release`, and if the file is removed again before its next
    poll it waits out the full 120s ceiling. The operator deletes `reached`
    on its way out, so that file disappearing is the confirmation. -/
private def releaseAndWait : IO Unit := do
  discard <| opExec s!"touch {barrierDir}/release"
  for _ in [0:60] do
    match ← opExec s!"test -f {barrierDir}/reached && echo held || echo free" with
    | .ok out => if containsSubstr out "free" then break
    | .error _ => break
    IO.sleep 1000

/-- Idempotent teardown for every exit path, including failures: release a
    pass if one is still held (so a failed assertion never leaves the
    operator parked), then clear the control files. -/
private def ensureBarrierClear : IO Unit := do
  match ← opExec s!"test -f {barrierDir}/reached && echo held || echo free" with
  | .ok out => if containsSubstr out "held" then releaseAndWait
  | .error _ => pure ()
  discard <| opExec s!"rm -f {barrierDir}/arm {barrierDir}/release {barrierDir}/reached"

private def leaseName : String := s!"{cfg.name}-operator-lease"

/-- Convergence that a stale map cannot satisfy.

    Counting registered nodes is not enough: after a suppressed broadcast the
    operator can hold a perfectly good map that no node ever received, and a
    count-only check passes while the cluster runs on the old topology. So
    require the operator to have exactly one Active master for the partition,
    every node Active, AND every flared pod to name that same master in its
    own view. -/
private def topologyApplied : IO (Except String Unit) := do
  let entries ← nodeView
  if entries.length < numPods then
    return .error s!"operator sees {entries.length}/{numPods} nodes"
  let masters := entries.filter (fun e => e.role == 0 && e.state == 0)
  match masters with
  | [m] =>
    if entries.any (fun e => e.state != 0) then
      return .error "some node is not Active in the operator's view"
    let expected := (m.fqdn.splitOn ".").headD m.fqdn
    let pods ← getPodNames s!"app=flare,cluster={cfg.name}" cfg.«namespace»
    for pod in pods do
      match ← getPodIp pod cfg.«namespace» with
      | none => return .error s!"no IP for {pod}"
      | some ip =>
        let roles ← flaredRoles ip
        let sawMaster := roles.any (fun r => containsSubstr r expected && containsSubstr r ":role master")
        if !sawMaster then
          return .error s!"{pod} does not name {expected} as master in its own view — the committed map has not been applied there"
    return .ok ()
  | _ => return .error s!"expected exactly one Active master, found {masters.length}"

/-- Survivor = a flared pod we do NOT disturb, so its node_map_version can
    only move when a broadcast reaches it. -/
private def survivorAndVictim : IO (Option (String × String)) := do
  let pods ← getPodNames s!"app=flare,cluster={cfg.name}" cfg.«namespace»
  match pods.head?, pods.reverse.head? with
  | some a, some b => return (if a == b then none else some (a, b))
  | _, _ => return none

/-- Cause a committed topology change WITHOUT disturbing any pod.

    Deleting a flared pod also works, but not here: these tests then remove
    the operator's authority, and a pod recreated in that window has no
    index server to register with, exits 255 and crash-loops — which is
    what the first attempt at these tests actually produced. Flipping the
    read-balance weight in the CR changes the committed map through the
    normal path and leaves every process alone. -/
private def triggerTopologyChange (weight : Nat) : IO (Except String String) :=
  kubectlPatch "flarecluster" cfg.name cfg.«namespace»
    s!"\{\"spec\":\{\"readBalance\":\{\"master\":100,\"slave\":{weight}}}}"

/-- Drive one pass to the barrier: arm, cause a topology change, and wait
    until the operator reports it is holding. Returns the held version. -/
private def stopOnePassBeforeLeaseCheck (weight : Nat) : IO (Except String Nat) := do
  match ← armBarrier with
  | .error e => return .error s!"could not arm the barrier: {e}"
  | .ok _ =>
    match ← triggerTopologyChange weight with
    | .error e => return .error s!"could not trigger a topology change: {e}"
    | .ok _ => pure ()
    let mut held : Option Nat := none
    for _ in [0:90] do
      held ← barrierHeldVersion
      if held.isSome then break
      IO.sleep 1000
    match held with
    | none => return .error "no pass reached the pre-send barrier within 90s; the stop position was never hit, so nothing below would prove anything"
    | some v => return .ok v

/-- The slave's balance as one flared pod sees it in its own map (`stats
    nodes`), or none if the pod does not list a slave. This is the CONTENT
    marker for the startup-republish test: the held change is a read-balance
    weight, so a pod that still shows the old weight has not applied the
    withheld map, whatever its version says. -/
private def flaredSlaveBalance (targetIp : String) : IO (Option Nat) := do
  let cmd := s!"printf 'stats nodes\\r\\n' | nc -w 3 {targetIp} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .error _ => return none
  | .ok output =>
    let lines := (output.splitOn "\n").map (fun l => (l.trim.replace "\r" ""))
    let slaveKey := lines.findSome? fun t =>
      if t.startsWith "STAT " && (t.endsWith ":role slave") then
        some ((t.drop 5).dropRight ":role slave".length)
      else none
    match slaveKey with
    | none => return none
    | some k =>
      return lines.findSome? fun t =>
        if t.startsWith s!"STAT {k}:balance " then (t.drop s!"STAT {k}:balance ".length).trim.toNat?
        else none

/-- The first `broadcast trigger:` record and the first broadcast line of a
    log, in order of appearance. -/
private def firstSend (log : String) : Option (String × String) :=
  let lines := log.splitOn "\n"
  let trig := lines.find? (containsSubstr · "broadcast trigger: ")
  let send := lines.find? (containsSubstr · "), broadcasting")
  match trig, send with
  | some t, some b =>
    some (((t.splitOn "broadcast trigger: ").getLast!).trim, b.trim)
  | _, _ => none

/-- "resuming at broadcast version N" from the operator's startup log. -/
private def resumedVersion (log : String) : Option Nat :=
  (log.splitOn "\n").findSome? fun l =>
    match (l.splitOn "resuming at broadcast version ").getLast? with
    | some rest => if containsSubstr l "resuming at broadcast version " then
        (rest.takeWhile Char.isDigit).toNat? else none
    | none => none

private def podIps : IO (List (String × String)) := do
  let pods ← getPodNames s!"app=flare,cluster={cfg.name}" cfg.«namespace»
  pods.filterMapM fun p => do return (← getPodIp p cfg.«namespace»).map (p, ·)

/-- Some `retrying an unconfirmed topology send (pending vP; publishing vQ)`
    line with P ≤ held ≤ Q: a retry whose pending flag was set no later than
    the withheld pass and whose published map subsumes it. -/
private def retryCovers (log : String) (held : Nat) : Bool :=
  (log.splitOn "\n").any fun l =>
    match (l.splitOn "retrying an unconfirmed topology send (pending v").getLast? with
    | none => false
    | some rest =>
      if !containsSubstr l "retrying an unconfirmed topology send (pending v" then false
      else
        let p := (rest.takeWhile Char.isDigit).toNat?
        let q := ((rest.splitOn "publishing v").getLast?.map (·.takeWhile Char.isDigit)).bind (·.toNat?)
        match p, q with
        | some p, some q => p ≤ held && held ≤ q
        | _, _ => false

-- ─── SAF-09: the persisted node map at startup ───────────────────────────

private def nodeMapCm : String := s!"{cfg.name}-node-map"

private def sh (cmd : String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := "sh", args := #["-c", cmd] }
  if out.exitCode == 0 then return .ok out.stdout else return .error out.stderr

private def scaleOperator (n : Nat) : IO Bool := do
  discard <| kubectl ["scale", "deployment", cfg.operatorName, "-n", cfg.«namespace», s!"--replicas={n}"]
  waitForCondition s!"operator scaled to {n}" 180 do
    let pods ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
    return pods.length == n

/-- Current and previous container logs of every operator pod. -/
private def operatorLogsAll : IO String := do
  let pods ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
  let mut acc := ""
  for pod in pods do
    for extra in [[], ["--previous"]] do
      match ← kubectl (["logs", "-n", cfg.«namespace», pod, "--tail=3000"] ++ extra) with
      | .ok o => acc := acc ++ o
      | .error _ => pure ()
  return acc

/-- The operator's index port (12120) accepts a connection on any operator
    pod. While the node map is undecided it must not: no flared can register
    and no topology can be served. Readiness is NOT this signal — a restarted
    operator is briefly a standby, and a standby is Ready by design. -/
private def indexServing : IO Bool := do
  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={.items[*].status.podIP}"] with
  | .error _ => return false
  | .ok ips =>
    for ip in (ips.trim.splitOn " ").filter (· != "") do
      match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"nc -z -w 2 {ip} {cfg.operatorPort} && echo OPEN || echo CLOSED" with
      | .ok o => if containsSubstr o "OPEN" then return true
      | .error _ => pure ()
    return false

/-- Sample `indexServing` for `secs` seconds; true if it was ever open. -/
private def indexEverServed (secs : Nat) : IO Bool := do
  for _ in [0:secs / 3] do
    if ← indexServing then return true
    IO.sleep 3000
  return false

private def operatorReady : IO Bool := do
  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={.items[*].status.containerStatuses[0].ready}"] with
  | .ok o => return o.trim == "true"
  | .error _ => return false

private def readNodeMap : IO (Option String) := do
  match ← kubectlGetJsonpath "configmap" nodeMapCm cfg.«namespace» "{.data.nodeMap}" with
  | .ok d => return if d.trim.isEmpty then none else some d
  | .error _ => return none

/-- Put the node-map ConfigMap back with exactly `data`. -/
private def writeNodeMap (data : String) : IO (Except String String) := do
  discard <| kubectl ["delete", "configmap", nodeMapCm, "-n", cfg.«namespace», "--ignore-not-found"]
  kubectl ["create", "configmap", nodeMapCm, "-n", cfg.«namespace», s!"--from-literal=nodeMap={data}"]

/-- Index of the ClusterRole rule granting configmaps. -/
private def configmapRuleIndex : IO (Option Nat) := do
  match ← sh "kubectl get clusterrole flare-operator -o json | jq -r '.rules | to_entries[] | select(.value.resources | index(\"configmaps\")) | .key' | head -1" with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

private def setConfigmapResource (i : Nat) (from_ to : String) : IO (Except String String) := do
  match ← sh s!"kubectl get clusterrole flare-operator -o json | jq -c '.rules[{i}].resources | map(if . == \"{from_}\" then \"{to}\" else . end)'" with
  | .error e => return .error e
  | .ok res =>
    kubectl ["patch", "clusterrole", "flare-operator", "--type=json", "-p",
      ("[{\"op\":\"replace\",\"path\":\"/rules/" ++ toString i ++ "/resources\",\"value\":" ++ res.trim ++ "}]")]

/-- Stop the operator, apply `fault` to the stored map, start it again, and
    return (the CRITICAL line seen, whether it ever became Ready). -/
private def restartUnder (fault : IO Unit) (needle : String) (window : Nat := 120) : IO (Bool × Bool) := do
  if !(← scaleOperator 0) then return (false, false)
  fault
  discard <| kubectl ["scale", "deployment", cfg.operatorName, "-n", cfg.«namespace», "--replicas=1"]
  let seen ← waitForCondition s!"the operator logs [{needle}]" window do
    return containsSubstr (← operatorLogsAll) needle
  return (seen, ← operatorReady)

def suite : TestSuite := {
  name := "topology-authority"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      IO.eprintln "# WARNING: cluster did not stabilize during setup"
  teardown := cleanupCluster cfg
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  tests := [
    { name := "flared rejects a topology push carrying a stale version"
      run := do
        let entries ← nodeView
        if entries.length < numPods then
          return .fail s!"cluster not converged before the test: {entries.length}/{numPods} nodes"
        let pods ← getPodNames s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        match pods.head? with
        | none => return .fail "no flared pod found"
        | some pod =>
        match ← getPodIp pod cfg.«namespace» with
        | none => return .fail s!"no IP for {pod}"
        | some ip =>
          match ← flaredStat ip "node_map_version" with
          | none => return .fail s!"could not read node_map_version from {pod}"
          | some version =>
            if version == 0 then
              return .fail "node_map_version is 0; nothing has been broadcast yet, so a stale push cannot be distinguished"
            let rolesBefore ← flaredRoles ip
            let logBefore ← kubectlLogs pod cfg.«namespace» 400
            let alreadyIgnored := containsSubstr logBefore "is newer than"
            -- Push a map that WOULD be visible if adopted, at a version the
            -- recipient must consider obsolete.
            let stale := version - 1
            IO.eprintln s!"# pushing a mutated map to {pod} at stale version {stale} (its current version is {version})"
            let payload := mutatedSyncPayload entries stale
            match ← execInDebugPod cfg.debugPod cfg.«namespace»
                s!"printf '{payload}' | nc -w 3 {ip} {cfg.flarePort}" with
            | .error e => return .fail s!"could not push the stale map from the debug pod: {e}"
            | .ok _ => pure ()
            IO.sleep 3000
            let rolesAfter ← flaredRoles ip
            let versionAfter ← flaredStat ip "node_map_version"
            let logAfter ← kubectlLogs pod cfg.«namespace» 400
            -- Arrival: flared must SAY it ignored it. Without this the test
            -- would also pass if the connection had failed outright.
            if alreadyIgnored then
              IO.eprintln "# note: the log already contained a rejection before the push; relying on state assertions"
            else if !containsSubstr logAfter "is newer than" then
              return .fail "flared never logged a version rejection — the push may not have arrived, so 'unchanged' proves nothing"
            if rolesAfter != rolesBefore then
              return .fail s!"flared ADOPTED a stale-version map: before={rolesBefore} after={rolesAfter}"
            if versionAfter != some version then
              return .fail s!"node_map_version moved on a stale push: {version} -> {versionAfter}"
            return .pass },

    -- The three tests below all stop the SAME production pass at the same
    -- point — committed, version advanced, lease not yet checked — and differ
    -- only in what happens to the lease while it is held there. Passing
    -- requires evidence the pass REACHED the fence branch, not merely that
    -- a receiver stayed still: a receiver also stays still when the
    -- operator crashed, timed out or never got that far.
    { name := "control: holding the lease, the stopped pass does broadcast"
      run := do
        match ← survivorAndVictim with
        | none => return .fail "need two flared pods"
        | some (survivor, _) =>
        match ← getPodIp survivor cfg.«namespace» with
        | none => return .fail s!"no IP for {survivor}"
        | some survivorIp =>
          let v0 ← flaredStat survivorIp "node_map_version"
          match ← stopOnePassBeforeLeaseCheck 40 with
          | .error e => ensureBarrierClear; return .fail e
          | .ok held =>
            IO.eprintln s!"# pass held at the pre-send point with version {held}"
            releaseAndWait
            IO.sleep 8000
            let log ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 400
            let v1 ← flaredStat survivorIp "node_map_version"
            ensureBarrierClear
            if !containsSubstr log s!"→ v{held}), broadcasting" then
              return .fail s!"the released pass did not take the broadcast branch for v{held}; without this control the suppression tests could pass for the wrong reason"
            if v1 != some held then
              return .fail s!"survivor did not receive the broadcast: {v0} -> {v1}, expected {held}"
            return .pass },

    { name := "lease taken by another identity: the pass fences, the process exits, and the restarted leader re-applies the topology"
      run := do
        match ← survivorAndVictim with
        | none => return .fail "need two flared pods"
        | some (survivor, _) =>
        match ← getPodIp survivor cfg.«namespace» with
        | none => return .fail s!"no IP for {survivor}"
        | some survivorIp =>
          match ← flaredStat survivorIp "node_map_version" with
          | none => return .fail "could not read the survivor's node_map_version"
          | some v0 =>
            match ← stopOnePassBeforeLeaseCheck 60 with
            | .error e => ensureBarrierClear; return .fail e
            | .ok held =>
              IO.eprintln s!"# pass held at the pre-send point with version {held}; taking the lease away now"
              let patch := "{\"spec\":{\"holderIdentity\":\"e2e-foreign-holder\",\"leaseDurationSeconds\":600,\"renewTime\":\"2999-01-01T00:00:00.000000Z\"}}"
              match ← kubectlPatch "lease" leaseName cfg.«namespace» patch with
              | .error e => ensureBarrierClear; return .fail s!"could not take the lease: {e}"
              | .ok _ =>
                let restarts0 := (← operatorRestarts).getD 0
                releaseAndWait
                -- The fence line may be in the container this pass ran in,
                -- which the designed exit replaces; read across the restart.
                let log ← fenceEvidence held restarts0
                let v1 ← flaredStat survivorIp "node_map_version"
                ensureBarrierClear
                -- Authority goes back (this harness runs one operator
                -- replica) on EVERY path below, so a failed assertion never
                -- leaves a cluster nobody owns — but only after the exit has
                -- been observed or ruled out: the process notices the foreign
                -- holder at its next lease check, and deleting the lease
                -- before that turns "lost to another identity" into
                -- "unreadable", which is the read-failure branch (test 4),
                -- not an exit. The first cut deleted it right after a fixed
                -- 8s sleep and only passed because 8s outlasted the tick.
                let restoreAuthority : IO Unit := do
                  match ← kubectl ["delete", "lease", leaseName, "-n", cfg.«namespace»] with
                  | .error e => IO.eprintln s!"# WARNING: could not delete the lease to restore authority: {e}"
                  | .ok out => IO.eprintln s!"# lease deleted to restore authority: {out.trim}"
                if !containsSubstr log s!"LEASE FENCE" then
                  restoreAuthority
                  return .fail s!"the resumed pass never reported the fence for v{held}; it may have crashed, timed out or exited before the check — no suppression is proved"
                if !containsSubstr log s!"→ v{held})" then
                  restoreAuthority
                  return .fail s!"a fence line exists but not for the pass that was held (v{held})"
                if heldPassBroadcast log held then
                  restoreAuthority
                  return .fail s!"the pass both fenced and broadcast v{held}"
                if v1 != some v0 then
                  restoreAuthority
                  return .fail s!"survivor's version moved while the lease was foreign: {v0} -> {v1}"
                -- Losing the lease ENDS the process ("LOST LEASE -- exiting"),
                -- so nothing in that operator's memory can retry: the
                -- requirement here is that the exit really happens (kubelet
                -- restarts the container) and that authority returning
                -- restores a correctly applied topology, whoever publishes
                -- it. The in-process retry is asserted in the read-failure
                -- test below, where the process survives.
                let exited ← waitForCondition "operator container restarted after losing the lease" 180 do
                  return ((← operatorRestarts).getD 0) > restarts0
                if !exited then
                  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-o", "wide"] with
                  | .ok out => IO.eprintln s!"# pods at failure:\n{out}"
                  | .error _ => pure ()
                  match ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 15 with
                  | out => IO.eprintln s!"# operator tail at failure:\n{out}"
                  restoreAuthority
                  return .fail s!"the operator logged the fence but did not exit: restartCount stayed at {restarts0} for 180s (a process that neither leads nor exits leaves the cluster unowned)"
                -- The exit is observed; the restarted process is waiting in
                -- phase 1 on a lease that never expires. Give it back.
                restoreAuthority
                let relead ← waitForCondition "restarted operator acquired the lease" 120 do
                  let fresh ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 400
                  return containsSubstr fresh "phase 2: acquired lease"
                if !relead then
                  return .fail "the restarted operator did not report acquiring the lease within 120s"
                let back ← waitForCondition "topology re-applied after leadership is restored" 240 do
                  return (← topologyApplied).toOption.isSome
                if !back then
                  -- Say WHY, with the state that decides it: guessing at this
                  -- from a bare assertion cost two runs already.
                  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-o", "wide"] with
                  | .ok out => IO.eprintln s!"# pods at failure:\n{out}"
                  | .error _ => pure ()
                  match ← kubectl ["get", "lease", leaseName, "-n", cfg.«namespace», "-o", "yaml"] with
                  | .ok out => IO.eprintln s!"# lease at failure:\n{out}"
                  | .error e => IO.eprintln s!"# lease at failure: absent ({e})"
                  match ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 40 with
                  | out => IO.eprintln s!"# operator tail at failure:\n{out}"
                  match ← topologyApplied with
                  | .error why => return .fail s!"topology was not re-applied after restoring leadership: {why}"
                  | .ok _ => return .fail "topology check flapped"
                return .pass },

    { name := "lease unreadable: the stopped pass fails closed and does not send"
      run := do
        match ← survivorAndVictim with
        | none => return .fail "need two flared pods"
        | some (survivor, _) =>
        match ← getPodIp survivor cfg.«namespace» with
        | none => return .fail s!"no IP for {survivor}"
        | some survivorIp =>
          match ← flaredStat survivorIp "node_map_version" with
          | none => return .fail "could not read the survivor's node_map_version"
          | some v0 =>
            match ← stopOnePassBeforeLeaseCheck 80 with
            | .error e => ensureBarrierClear; return .fail e
            | .ok held =>
              IO.eprintln s!"# pass held at the pre-send point with version {held}; deleting the lease so the read fails"
              discard <| kubectl ["delete", "lease", leaseName, "-n", cfg.«namespace»]
              releaseAndWait
              IO.sleep 8000
              let log ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 400
              let v1 ← flaredStat survivorIp "node_map_version"
              ensureBarrierClear
              if !containsSubstr log "lease fence: getLease failed" then
                return .fail s!"no evidence the resumed pass hit the read-failure branch for v{held}"
              -- The retry below legitimately broadcasts v{held} from a LATER
              -- pass (old == new); only a send with the held pass's own
              -- old < new shape is the failure.
              if heldPassBroadcast log held then
                return .fail s!"the pass broadcast v{held} despite an unreadable lease"
              IO.eprintln s!"# read-failure pass suppressed v{held}; survivor version {v0} -> {v1} (any movement is post-restart recovery, not the suppressed pass)"
              -- What proves the suppressed pass failed closed is the pair of
              -- log facts above (the read-failure branch was hit for v{held},
              -- and v{held} was not broadcast), not the survivor's version
              -- holding still. The version legitimately moves here: losing the
              -- lease ends the process, kubelet restarts it, and the restarted
              -- leader broadcasts to catch up (and re-sends to any node not yet
              -- Ready). Asserting the version is unchanged would fail on that
              -- recovery and, worse, contradicts the retry below, which
              -- REQUIRES the version to advance. (v0 = {v0}, v1 = {v1}.)
              -- RETRY, in this process. A read failure does not cost the
              -- operator its leadership — it recreates the lease on the next
              -- tick — so the map it withheld must go out without waiting for
              -- an unrelated change. Before the retry existed this was
              -- terminal: the committed version had already advanced, so the
              -- next pass found nothing to send and the node kept the old map.
              let delivered ← waitForCondition "the withheld topology is retried by the same process" 180 do
                match ← flaredStat survivorIp "node_map_version" with
                | some v => return v ≥ held
                | none => return false
              let log2 ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 400
              if !delivered then
                let vNow ← flaredStat survivorIp "node_map_version"
                return .fail s!"the withheld topology was never retried: survivor still at {vNow}, expected at least {held}"
              -- The sending pass must name THIS suppression. The line is
              -- logged whether or not the version also moved, so what it
              -- proves is that the flag was set by the withheld pass and
              -- consumed by the pass that published; it does not isolate
              -- the flag as the only reason that pass sent (in a live
              -- cluster the version often moves by itself). Recorded as a
              -- residual in the register rather than papered over here.
              -- The pending flag keeps the EARLIEST outstanding version and a
              -- retry publishes the LATEST committed map (TopologyBroadcast:
              -- pendingTopologyAfterAttempt). So the retry that covers v{held}
              -- names some pending vP ≤ held and publishes some vQ ≥ held. P
              -- is below held when an earlier send was already outstanding:
              -- CI 36731888436, where this pass was the restarted process's
              -- first, so its startup seed (v…306) was still pending when the
              -- fence withheld v…307, and the retry published v…308.
              if !(retryCovers log2 held) then
                return .fail s!"the survivor caught up, but no retry line covers the suppressed v{held} (pending ≤ {held} ≤ publishing): the withheld map was not what the retry carried"
              let back ← waitForCondition "topology re-applied after the lease is recreated" 240 do
                return (← topologyApplied).toOption.isSome
              if !back then
                match ← topologyApplied with
                | .error why => return .fail s!"topology was not re-applied after the lease was recreated: {why}"
                | .ok _ => return .fail "topology check flapped"
              return .pass },

    { name := "SAF-09: the Lease is deleted and the operator replaced; the new leader's generation is above the persisted record's even though the Lease count restarted, and its maps are accepted"
      run := do
        let settled ← waitForCondition "topology applied before the generation test" 240 do
          return (← topologyApplied).toOption.isSome
        if !settled then return .fail "precondition: topology not applied before the test"
        let persistedVersion : IO (Option Nat) := do
          match ← kubectlGetJsonpath "configmap" s!"{cfg.name}-node-map" cfg.«namespace» "{.data.nodeMap}" with
          | .ok d => return (d.splitOn "\n").findSome? fun l =>
              if l.startsWith "version=" then (l.drop "version=".length).trim.toNat? else none
          | .error _ => return none
        match ← persistedVersion with
        | none => return .fail "precondition: no persisted node-map version"
        | some vP =>
        let ips ← podIps
        let before ← ips.mapM fun (_, ip) => flaredStat ip "node_map_version"
        IO.eprintln s!"# persisted version {vP} (generation {vP / 4294967296}); pods at {before}"
        let opPods0 ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
        -- Delete the Lease and replace the operator: the new process finds no
        -- Lease, creates one, and its Lease count starts again.
        discard <| kubectl ["delete", "lease", leaseName, "-n", cfg.«namespace»]
        discard <| kubectl ["delete", "pod", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "--wait=false"]
        let replaced ← waitForCondition "the operator pod is replaced and the old one is gone" 240 do
          let now ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
          return !now.isEmpty && !now.any (opPods0.contains ·)
        if !replaced then return .fail "precondition: the operator pod was not replaced"
        let genLine : IO (Option String) := do
          let log ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 3000
          return ((log.splitOn "\n").find? (containsSubstr · "leadership generation ")).map String.trim
        let logged ← waitForCondition "the new leader logs its generation" 180 do
          return (← genLine).isSome
        let line := (← genLine).getD ""
        IO.eprintln s!"# {line}"
        if !logged then return .fail "the new leader never logged its generation"
        let num := fun (key : String) =>
          ((line.splitOn key).getLast?.map (fun r => r.takeWhile Char.isDigit)).bind (·.toNat?)
        match num "leadership generation ", num "lease transitions " with
        | some g, some t =>
          if g ≤ vP / 4294967296 then
            return .fail s!"the new leader's generation {g} is not above the persisted generation {vP / 4294967296} (lease transitions {t}): it could rank below maps already issued"
          -- Its maps must actually be accepted: a change made now reaches
          -- every pod at a version above what they held.
          match ← triggerTopologyChange 45 with
          | .error e => return .fail s!"could not trigger a topology change: {e}"
          | .ok _ => pure ()
          let accepted ← waitForCondition "every pod accepts the new leader's map" 180 do
            let now ← ips.mapM fun (_, ip) => flaredStat ip "node_map_version"
            return now.all fun v => match v with | some n => n ≥ g * 4294967296 | none => false
          let after ← ips.mapM fun (_, ip) => flaredStat ip "node_map_version"
          IO.eprintln s!"# generation {g} (lease transitions {t}); pods {before} -> {after}"
          if !accepted then return .fail s!"the pods did not accept the new leader's maps: {before} -> {after}"
          let back ← waitForCondition "topology applied under the new leader" 240 do
            return (← topologyApplied).toOption.isSome
          if !back then return .fail "topology not applied under the new leader"
          return .pass
        | _, _ => return .fail s!"could not parse the generation line: {line}" },

    { name := "same-name Pod replacement during the topology probe: the probe is held after its first UID read, the pod is replaced under the same name, and the reply is judged Unknown (never current or behind); the new pod is later observed current"
      run := do
        let settled ← waitForCondition "topology applied before the replacement test" 240 do
          return (← topologyApplied).toOption.isSome
        if !settled then return .fail "precondition: topology not applied before the test"
        let entries ← nodeView
        match entries.find? (·.role == 1) with
        | none => return .fail "precondition: no slave in the operator's view"
        | some sl =>
        let pod := (sl.fqdn.splitOn ".").headD sl.fqdn
        let uidOf : IO (Option String) := do
          match ← kubectlGetJsonpath "pod" pod cfg.«namespace» "{.metadata.uid}" with
          | .ok u => return (if u.trim.isEmpty then none else some u.trim)
          | .error _ => return none
        match ← uidOf with
        | none => return .fail s!"precondition: no UID for {pod}"
        | some uid0 =>
        let release : IO Unit := do
          discard <| opExec s!"touch {barrierDir}/probe-release"
          for _ in [0:40] do
            match ← opExec s!"test -f {barrierDir}/probe-reached && echo held || echo free" with
            | .ok out => if containsSubstr out "free" then break
            | .error _ => break
            IO.sleep 500
        match ← opExec s!"mkdir -p {barrierDir} && rm -f {barrierDir}/probe-reached {barrierDir}/probe-release && touch {barrierDir}/probe-arm-{pod}" with
        | .error e => return .fail s!"could not arm the probe barrier: {e}"
        | .ok _ => pure ()
        -- The audit probes one node per pass, round robin, so the slave's
        -- turn comes within a few passes.
        let mut heldUid : Option String := none
        for _ in [0:90] do
          match ← opExec s!"cat {barrierDir}/probe-reached 2>/dev/null || true" with
          | .ok out => if !out.trim.isEmpty then heldUid := some out.trim
          | .error _ => pure ()
          if heldUid.isSome then break
          IO.sleep 1000
        match heldUid with
        | none =>
          discard <| opExec s!"rm -f {barrierDir}/probe-arm-{pod}"
          return .fail s!"the probe of {pod} never reached the hold within 90 s; nothing below would prove anything"
        | some h =>
        if h != uid0 then
          release
          return .fail s!"the held probe read uid {h}, not {pod}'s uid {uid0}"
        IO.eprintln s!"# probe of {pod} held after reading uid {uid0}; replacing the pod under the same name"
        discard <| kubectl ["delete", "pod", pod, "-n", cfg.«namespace», "--grace-period=0", "--force", "--wait=false"]
        -- Release as soon as the replacement exists: the hold blocks the
        -- loop that renews the 15 s lease.
        let mut uid1 : Option String := none
        for _ in [0:40] do
          let u ← uidOf
          if u.isSome && u != some uid0 then
            uid1 := u
            break
          IO.sleep 500
        release
        match uid1 with
        | none => return .fail s!"precondition: {pod} was not replaced under the same name within 20 s"
        | some newUid =>
        IO.eprintln s!"# {pod} replaced: uid {uid0} -> {newUid}; probe released"
        let verdictLine : IO (Option String) := do
          let log ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 3000
          let lines := log.splitOn "\n"
          let after := lines.dropWhile (fun l => !containsSubstr l s!"TEST SEAM: topology probe of {pod} released")
          return (after.find? (fun l => containsSubstr l s!"[TopologyAudit] node={pod}.")).map String.trim
        let judged ← waitForCondition "the held probe's verdict is logged" 30 do
          return (← verdictLine).isSome
        let line := (← verdictLine).getD ""
        IO.eprintln s!"# verdict of the held probe: {line}"
        if !judged then
          return .fail "no audit line for the held probe after its release"
        if !containsSubstr line "verdict=unknown" then
          return .fail s!"the probe bracketed by two different UIDs was not judged Unknown: {line}"
        -- Control: once the replacement has registered, the audit observes
        -- it normally. Unknown must clear by a fresh observation, not stick.
        let current ← waitForCondition "the replaced pod is observed current by a later probe" 240 do
          let log ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 3000
          return (log.splitOn "\n").any (fun l =>
            containsSubstr l s!"[TopologyAudit] node={pod}." && containsSubstr l newUid && containsSubstr l "verdict=current")
        if !current then
          return .fail s!"the replaced pod {pod} (uid {newUid}) was never observed current afterwards"
        let back ← waitForCondition "topology applied after the replacement" 240 do
          return (← topologyApplied).toOption.isSome
        if !back then return .fail "topology was not re-applied after the replacement"
        return .pass },

    { name := "startup republish alone: a map committed but never sent (operator replaced while the pass is held before the send) reaches every pod from the fresh process's first pass, topology audit off"
      run := do
        -- Precondition: the previous test leaves a re-created lease and a
        -- converged map. Start from the same place every time.
        let settled ← waitForCondition "topology applied before the startup-republish test" 240 do
          return (← topologyApplied).toOption.isSome
        if !settled then return .fail "precondition: topology not applied before the test"
        let ips ← podIps
        if ips.length < numPods then return .fail s!"precondition: {ips.length}/{numPods} flared pods have an IP"
        let before ← ips.mapM fun (pod, ip) => do
          return (pod, ← flaredStat ip "node_map_version", ← flaredSlaveBalance ip)
        IO.eprintln s!"# before: {before}"
        let opPods0 ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
        -- Slave weight 25, on purpose. Before the node map persisted each
        -- node's balance, a reloaded map had every node at 100 and the first
        -- pass, re-applying spec.readBalance, saw a changed map and advanced
        -- the version (CI 36831110279: first send versionMoved=true), a
        -- second reason to send. With balance persisted the reload changes
        -- nothing, so the startup seed is the only reason left; a weight
        -- other than 100 keeps this test a regression guard for that. The
        -- previous test leaves the weight at 80, so the content marker moves.
        match ← stopOnePassBeforeLeaseCheck 25 with
        | .error e => ensureBarrierClear; return .fail e
        | .ok held =>
          IO.eprintln s!"# pass held at the pre-send point with version {held}; replacing the operator (rollout with FLARE_TEST_TOPOLOGY_AUDIT_OFF=1) while it is held"
          -- The held pass is committed and persisted but has not sent. Lease
          -- renewal runs in the same loop, so the held process stops
          -- renewing; the new pod takes the lease once it expires, and the
          -- old process, if its barrier times out first, finds a foreign
          -- holder and fences. Either way it never sends.
          let persisted ← kubectlGetJsonpath "configmap" s!"{cfg.name}-node-map" cfg.«namespace» "{.metadata.resourceVersion}"
          IO.eprintln s!"# node-map ConfigMap resourceVersion at hold: {persisted.toOption.getD "?"}"
          match ← kubectl ["set", "env", s!"deployment/{cfg.operatorName}", "-n", cfg.«namespace», "FLARE_TEST_TOPOLOGY_AUDIT_OFF=1"] with
          | .error e => ensureBarrierClear; return .fail s!"could not roll the operator: {e}"
          | .ok _ => pure ()
          let rolled ← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" cfg.«namespace» 300
          -- `rollout status` returns once the NEW pod is available, and the
          -- operator reports Ready before it holds the lease, so the old pod
          -- can still be terminating here (CI 36826494031). Wait for it to be
          -- gone: until then the label selects both pods and the log read
          -- below would mix the two processes.
          let oldGone ← waitForCondition "the old operator pod is gone" 180 do
            let now ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
            return !now.isEmpty && !now.any (opPods0.contains ·)
          let opPods1 ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
          IO.eprintln s!"# operator pods before {opPods0}, after {opPods1} (rollout complete={rolled})"
          if !rolled || !oldGone then
            return .fail s!"precondition: operator was not replaced (rollout complete={rolled}, pods before {opPods0}, after {opPods1})"
          let sent ← waitForCondition "the fresh operator's first broadcast" 180 do
            let log ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 3000
            return (firstSend log).isSome
          let log ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 3000
          if !sent then
            let tail := String.intercalate "\n" ((log.splitOn "\n").reverse.take 40).reverse
            IO.eprintln s!"# fresh operator tail:\n{tail}"
            return .fail "the fresh operator never broadcast within 180s"
          if !containsSubstr log "TEST SEAM: topology audit disabled" then
            return .fail "precondition: the fresh operator does not report the audit seam; a behind recipient could have triggered the send"
          if containsSubstr log "[TopologyAudit] node=" then
            return .fail "precondition: the topology audit ran in the fresh operator despite the seam"
          match resumedVersion log with
          | none => return .fail "the fresh operator did not report resuming from the persisted map"
          | some r =>
          if r < held then
            return .fail s!"the fresh operator resumed at v{r}, below the held v{held}: the held map was not persisted before the send"
          match firstSend log with
          | none => return .fail "unreachable: first send vanished"
          | some (trig, line) =>
          IO.eprintln s!"# resumed at v{r}; first send: [{trig}] {line}"
          -- Startup republish ALONE: the pending flag is the only reason, and
          -- with the audit off the startup seed is the only thing that sets
          -- it in a fresh process.
          let pendingOnly := containsSubstr trig "versionMoved=false" &&
            containsSubstr trig "repairHeld=0" && containsSubstr trig "activeNotReady=0" &&
            !containsSubstr trig "pending=none"
          if !pendingOnly then
            return .fail s!"the fresh operator's first send is not attributable to the startup republish alone: [{trig}]"
          let x := (((trig.splitOn "pending=v").getLast!).takeWhile Char.isDigit).toNat!
          if !containsSubstr line s!"(v{x} → v{x}), broadcasting" then
            return .fail s!"trigger names pending v{x} but the broadcast line is {line}"
          let expected := (← nodeView).find? (·.role == 1) |>.map (·.balance)
          let applied ← waitForCondition "every pod adopts the republished map" 60 do
            let now ← ips.mapM fun (_, ip) => do return (← flaredStat ip "node_map_version", ← flaredSlaveBalance ip)
            return now.all fun (v, b) => v == some x && b == expected
          let after ← ips.mapM fun (pod, ip) => do
            return (pod, ← flaredStat ip "node_map_version", ← flaredSlaveBalance ip)
          IO.eprintln s!"# after: {after}; committed slave balance {expected}"
          if !applied then
            return .fail s!"not every pod applied the republished v{x} with slave balance {expected}: {after}"
          -- The content must actually have changed, otherwise the version
          -- moving is all this proves.
          if before.all (fun (_, _, b) => b == expected) then
            return .fail s!"precondition: the held change is not visible in the slave balance (before {before}, committed {expected}); the content marker proves nothing"
          return .pass },

    { name := "SAF-09: the persisted node map is missing at startup while the cluster has history: the operator halts (CRITICAL), never starts from an empty map; flared keeps serving; restoring the ConfigMap brings the operator back on the same map"
      run := do
        let settled ← waitForCondition "topology applied before the node-map test" 240 do
          return (← topologyApplied).toOption.isSome
        if !settled then return .fail "precondition: topology not applied"
        match ← readNodeMap with
        | none => return .fail "precondition: no persisted node map"
        | some saved =>
          let ips ← podIps
          let before ← ips.mapM fun (_, ip) => flaredStat ip "node_map_version"
          let (halted, ready) ← restartUnder (do discard <| kubectl ["delete", "configmap", nodeMapCm, "-n", cfg.«namespace»])
            "refusing to start from an empty map"
          let fresh := containsSubstr (← operatorLogsAll) "node map: starting fresh"
          -- the data plane keeps its last topology meanwhile
          let still ← ips.mapM fun (_, ip) => flaredStat ip "node_map_version"
          let (_, ip0) := ips.head!
          let served ← memcachedSet cfg.debugPod cfg.«namespace» ip0 cfg.flarePort "nm_probe" "alive"
          IO.eprintln s!"# map deleted: halted={halted} started fresh={fresh} operator ready={ready}; flared versions {before} -> {still}; set through a flared pod={served}"
          if fresh then return .fail "the operator started from an empty map although the cluster had history"
          if !halted then return .fail "the operator did not halt with the CRITICAL line"
          if ready then return .fail "the operator became Ready without its node map"
          if still != before then return .fail s!"flared's map changed while the operator was halted ({before} -> {still})"
          if !served then return .fail "flared stopped serving while the operator was halted"
          match ← writeNodeMap saved with
          | .error e => return .fail s!"could not restore the ConfigMap: {e}"
          | .ok _ => pure ()
          let back ← waitForCondition "the operator loads the restored map and is Ready" 300 do
            return (← operatorReady) && containsSubstr (← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 3000) "loaded "
          IO.eprintln s!"# restored: operator back={back}"
          if !back then return .fail "the operator did not come back on the restored map"
          let applied ← waitForCondition "topology applied after the restore" 240 do
            return (← topologyApplied).toOption.isSome
          if !applied then return .fail "topology not applied after the restore"
          return .pass },

    { name := "SAF-09: the persisted node map is corrupt at startup: the operator halts (CRITICAL invalid) instead of loading part of it or starting fresh; restoring it brings the operator back"
      run := do
        match ← readNodeMap with
        | none => return .fail "precondition: no persisted node map"
        | some saved =>
          -- drop the version line and break one node line
          let lines := (saved.splitOn "\n").filter (fun l => !l.startsWith "version=" && l.trim != "")
          let corrupt := "\n".intercalate (lines.map fun l => l.replace "role=" "role=x")
          let (halted, ready) ← restartUnder (do discard <| writeNodeMap corrupt) "the persisted node map is invalid"
          let fresh := containsSubstr (← operatorLogsAll) "node map: starting fresh"
          IO.eprintln s!"# map corrupted: halted={halted} started fresh={fresh} operator ready={ready}"
          match ← writeNodeMap saved with
          | .error e => return .fail s!"could not restore the ConfigMap: {e}"
          | .ok _ => pure ()
          if fresh then return .fail "the operator started fresh from a corrupt map"
          if !halted then return .fail "the operator did not halt on a corrupt map"
          if ready then return .fail "the operator became Ready on a corrupt map"
          let back ← waitForCondition "the operator loads the restored map and is Ready" 300 do
            return (← operatorReady)
          if !back then return .fail "the operator did not come back on the restored map"
          return .pass },

    { name := "SAF-09: the node map cannot be read at startup (RBAC forbids configmaps): the operator retries and does not start fresh; once readable it loads the existing map"
      run := do
        match ← configmapRuleIndex with
        | none => return .fail "no ClusterRole rule grants configmaps"
        | some i =>
          let before ← readNodeMap
          let (retried, _) ← restartUnder
            (do discard <| setConfigmapResource i "configmaps" "configmaps-e2e-revoked")
            "node map: retrying in 5 s" 90
          let fresh := containsSubstr (← operatorLogsAll) "node map: starting fresh"
          discard <| setConfigmapResource i "configmaps-e2e-revoked" "configmaps"
          IO.eprintln s!"# configmaps forbidden: retried={retried} started fresh={fresh}"
          if fresh then return .fail "a failed read made the operator start fresh"
          if !retried then return .fail "the operator did not retry the failed read"
          let back ← waitForCondition "the operator loads the existing map once readable" 300 do
            return (← operatorReady) && containsSubstr (← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 3000) "loaded "
          let after ← readNodeMap
          IO.eprintln s!"# readable again: operator back={back}; map kept={(before.map (·.length)) == (after.map (·.length)) || after.isSome}"
          if !back then return .fail "the operator did not load the map once it was readable"
          return .pass },
    { name := "SAF-09 compound failure: the map is deleted, the Lease marker is gone and every flared pod is restarting while the operator is down — the past cannot be observed, so the operator retries and never starts fresh (the first-build approval was consumed); restoring the map brings it back"
      run := do
        match ← readNodeMap with
        | none => return .fail "precondition: no persisted node map"
        | some saved =>
          let approval ← match ← kubectlGetJsonpath "flarecluster" cfg.name cfg.«namespace» "{.metadata.annotations.flare\\.gree\\.net/first-build-approved}" with
            | .ok v => pure v.trim
            | .error _ => pure ""
          IO.eprintln s!"# first-build approval still on the FlareCluster: [{approval}] (must be consumed after the first persist)"
          if !approval.isEmpty then return .fail "the first-build approval was not consumed after the first persisted map: it would authorize a fresh start after any later loss"
          let fault : IO Unit := do
            discard <| kubectl ["delete", "configmap", nodeMapCm, "-n", cfg.«namespace»]
            discard <| kubectl ["annotate", "lease", leaseName, "-n", cfg.«namespace», "flare.gree.net/node-map-persisted-"]
            discard <| kubectl ["delete", "pod", "-n", cfg.«namespace», "-l", s!"app=flare,cluster={cfg.name}", "--wait=false"]
            -- the replacements start and cannot register (no operator):
            -- give them time to be recreated, not to become readable
            IO.sleep 15000
          let (undecided, ready) ← restartUnder fault "cannot be told from a loss" 150
          -- CI 37278389267: "ready" was true here — the undecided operator
          -- exits (code 2) and restarts, and the restarted process is briefly
          -- a standby, which is Ready by design. What must hold is that it
          -- never serves the index, never starts fresh, writes no map.
          let served ← indexEverServed 60
          let logs ← operatorLogsAll
          let fresh := containsSubstr logs "node map: starting fresh"
          let mapWritten := (← readNodeMap).isSome
          let historyLine := ((logs.splitOn "\n").find? (containsSubstr · "node map history:")).getD "(none)"
          IO.eprintln s!"# compound: undecided logged={undecided} started fresh={fresh} index ever served={served} map written={mapWritten} (readiness observed {ready}: a restarted standby is Ready by design)\n# {historyLine.trim}"
          if fresh then return .fail "the operator started from an empty map although the past could not be observed"
          if !undecided then return .fail "the operator did not report that a first build cannot be told from a loss"
          if served then return .fail "the operator served the index without its node map"
          if mapWritten then return .fail "a node map was written without a decision"
          match ← writeNodeMap saved with
          | .error e => return .fail s!"could not restore the ConfigMap: {e}"
          | .ok _ => pure ()
          let back ← waitForCondition "the operator loads the restored map and is Ready" 360 do
            return (← operatorReady) && containsSubstr (← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 3000) "loaded "
          IO.eprintln s!"# restored: operator back={back}"
          if !back then return .fail "the operator did not come back on the restored map"
          let applied ← waitForCondition "topology applied after the restore" 300 do
            return (← topologyApplied).toOption.isSome
          if !applied then return .fail "topology not applied after the restore"
          return .pass }
  ]
}

end FlareOperator.E2E.Tests.TopologyAuthority
