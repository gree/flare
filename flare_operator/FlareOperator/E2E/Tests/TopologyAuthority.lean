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

  SENDER. The second test takes the lease away and asserts no topology
  reaches a surviving pod while someone else holds it. It tests the
  constraint end to end, NOT specifically the post-commit fence branch: a
  follower also stops reconciling, so both mechanisms would satisfy it.
  Isolating the fence needs the lease to change mid-pass, which is a race
  this harness cannot schedule.
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

private def cfg : ClusterConfig := {
  name := "topo-auth"
  «namespace» := "flare-topo-auth"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-topo-auth"
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

    { name := "no topology reaches a surviving pod while another holder owns the lease"
      run := do
        let entries ← nodeView
        if entries.length < numPods then
          return .fail s!"cluster not converged: {entries.length}/{numPods}"
        let pods ← getPodNames s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        match pods.head?, pods.reverse.head? with
        | some survivor, some victim =>
          if survivor == victim then
            return .fail "need at least two flared pods for this test"
          match ← getPodIp survivor cfg.«namespace» with
          | none => return .fail s!"no IP for {survivor}"
          | some survivorIp =>
            match ← flaredStat survivorIp "node_map_version" with
            | none => return .fail s!"could not read node_map_version from {survivor}"
            | some v0 =>
              let lease := s!"{cfg.name}-operator-lease"
              let patch := "{\"spec\":{\"holderIdentity\":\"e2e-foreign-holder\",\"leaseDurationSeconds\":600,\"renewTime\":\"2999-01-01T00:00:00.000000Z\"}}"
              match ← kubectlPatch "lease" lease cfg.«namespace» patch with
              | .error e => return .fail s!"could not take the lease away: {e}"
              | .ok _ =>
                IO.eprintln s!"# lease {lease} now held by e2e-foreign-holder; forcing a topology change"
                kubectlDelete "pod" victim cfg.«namespace»
                -- Long enough for several reconcile ticks and for the
                -- replacement pod to come back and re-register.
                IO.sleep 45000
                let v1 ← flaredStat survivorIp "node_map_version"
                let opLog ← kubectlLogsLabel "app=flare-operator" cfg.«namespace» 300
                -- Restore leadership by deleting the lease AND restarting the
                -- operator. Deleting the lease alone lets the SAME process
                -- re-acquire, and in that path it was observed broadcasting a
                -- LOWER version than the nodes already held — which flared
                -- then fences off, so the cluster cannot converge. That is a
                -- finding in its own right (recorded against SAF-09), not
                -- something this test should assert on, so restore the way an
                -- operator would: with a fresh process, which re-fences the
                -- generation on startup.
                match ← kubectl ["delete", "lease", lease, "-n", cfg.«namespace»] with
                | .error e => IO.eprintln s!"# warning: could not delete the lease: {e}"
                | .ok _ => pure ()
                match ← kubectl ["delete", "pod", "-n", cfg.«namespace»,
                                  "-l", s!"app={cfg.operatorName}", "--force", "--grace-period=0"] with
                | .error e => IO.eprintln s!"# warning: could not restart the operator: {e}"
                | .ok _ => pure ()
                if v1 != some v0 then
                  return .fail s!"a surviving pod's node_map_version advanced ({v0} -> {v1}) while a foreign identity held the lease — topology was published without authority"
                IO.eprintln s!"# survivor stayed at version {v0} while the lease was foreign"
                if containsSubstr opLog "LEASE FENCE" then
                  IO.eprintln "# operator logged the post-commit lease fence"
                else
                  IO.eprintln "# note: no LEASE FENCE line; the operator most likely never reached the send because it stopped reconciling as a follower"
                -- Leadership restored: the cluster must converge again,
                -- otherwise this test has left a broken cluster behind.
                let back ← waitForCondition "cluster converges after leadership is restored" 240 do
                  return (← nodeView).length ≥ numPods
                if !back then
                  return .fail "cluster did not converge after the lease was restored"
                return .pass
        | _, _ => return .fail "could not list two flared pods" }
  ]
}

end FlareOperator.E2E.Tests.TopologyAuthority
