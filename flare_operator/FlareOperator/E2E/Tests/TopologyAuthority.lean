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
  operatorEnv := [("FLARE_TEST_PRESEND_BARRIER", barrierDir)]
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
                IO.sleep 8000
                let log ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 400
                let v1 ← flaredStat survivorIp "node_map_version"
                ensureBarrierClear
                -- Hand authority back to the SAME process (this harness runs
                -- one operator replica), before judging, so a failed
                -- assertion never leaves a cluster nobody owns.
                match ← kubectl ["delete", "lease", leaseName, "-n", cfg.«namespace»] with
                | .error e => IO.eprintln s!"# WARNING: could not delete the lease to restore authority: {e}"
                | .ok out => IO.eprintln s!"# lease deleted to restore authority: {out.trim}"
                if !containsSubstr log s!"LEASE FENCE" then
                  return .fail s!"the resumed pass never reported the fence for v{held}; it may have crashed, timed out or exited before the check — no suppression is proved"
                if !containsSubstr log s!"→ v{held})" then
                  return .fail s!"a fence line exists but not for the pass that was held (v{held})"
                if containsSubstr log s!"→ v{held}), broadcasting" then
                  return .fail s!"the pass both fenced and broadcast v{held}"
                if v1 != some v0 then
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
                  return .fail s!"the operator logged the fence but did not exit: restartCount stayed at {restarts0} for 180s (a process that neither leads nor exits leaves the cluster unowned)"
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
              if containsSubstr log s!"→ v{held}), broadcasting" then
                return .fail s!"the pass broadcast v{held} despite an unreadable lease"
              if v1 != some v0 then
                return .fail s!"survivor's version moved on a pass whose lease read failed: {v0} -> {v1}"
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
              if !containsSubstr log2 s!"retrying a suppressed topology send (suppressed v{held}" then
                return .fail s!"the survivor caught up, but no publishing pass named the suppressed v{held}: the withheld map was not what the retry carried"
              let back ← waitForCondition "topology re-applied after the lease is recreated" 240 do
                return (← topologyApplied).toOption.isSome
              if !back then
                match ← topologyApplied with
                | .error why => return .fail s!"topology was not re-applied after the lease was recreated: {why}"
                | .ok _ => return .fail "topology check flapped"
              return .pass }
  ]
}

end FlareOperator.E2E.Tests.TopologyAuthority
