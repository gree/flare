/-
  E2E/Tests/FirstBuildWait.lean — a new cluster's first build waits for the
  first-build approval without a restart.

  Before: with no node map, an unobservable past and no approval the operator
  retried 12 times and exited (CrashLoopBackOff), and every flared exited
  because the operator did not serve its index yet. Now the operator keeps
  its Lease and waits (not Ready, no index, no map), and flared retries its
  FIRST index connection. The approval can come any time after the
  FlareCluster exists.

  Order: the FlareCluster and its StatefulSet are created WITHOUT approval;
  minutes pass (restarts 0, no map, Lease held, waiting gauge 1); an
  approval carrying a WRONG uid changes nothing; the approval with the
  FlareCluster's own uid lets the cluster build, still without a restart.
  The stops that must stay (history seen, map read failure / invalid map)
  are covered by the existing SAF-09 suites (topology-authority,
  cluster-init) and the unit decision table.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.FirstBuildWait

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "fb-wait"
  «namespace» := "flare-fb-wait"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-fb-wait"
  storageBackend := "rocksdb"
  deferClusterCr := true
}

private def ns : String := cfg.«namespace»
private def leaseName : String := s!"{cfg.name}-operator-lease"
private def annotation : String := "{.metadata.annotations.flare\\.gree\\.net/first-build-approved}"

/-- restart counts ("name=count") of the pods matching a label -/
private def restartsOf (label : String) : IO (List (String × Nat)) := do
  match ← kubectl ["get", "pods", "-n", ns, "-l", label, "-o",
      "jsonpath={range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount}{\"\\n\"}{end}"] with
  | .ok o => return (o.splitOn "\n").filterMap fun l =>
      match l.trim.splitOn "=" with
      | [n, c] => c.toNat?.map (n, ·)
      | _ => none
  | .error _ => return []

private def opLog (tail : Nat := 3000) : IO String :=
  kubectlLogsLabel s!"app={cfg.operatorName}" ns tail

private def nodeMapExists : IO Bool := do
  return (← kubectlGetJsonpath "configmap" s!"{cfg.name}-node-map" ns "{.metadata.name}").toOption.isSome

/-- the operator's waiting gauge as exported (the metrics server runs before
    the node-map decision) -/
private def waitingGauge : IO (Option String) := do
  match ← getPodIps s!"app={cfg.operatorName}" ns with
  | [] => return none
  | ip :: _ =>
    match ← execInDebugPod cfg.debugPod ns s!"printf 'GET /metrics HTTP/1.0\\r\\n\\r\\n' | nc -w 3 {ip} 9090" with
    | .error _ => return none
    | .ok out => return (out.splitOn "\n").find? (fun l => containsSubstr l "flare_operator_first_build_waiting{")

def suite : TestSuite := {
  name := "first-build-wait"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    -- the CR and the StatefulSet, deliberately WITHOUT the approval
    deployDeferredCluster cfg false
  teardown := cleanupCluster cfg
  onFailure := dumpClusterDiagnostics ns s!"app={cfg.operatorName}"
  tests := [
    { name := "no approval for minutes: operator and flared pods do not restart, no map is distributed, the Lease is held, the waiting gauge is 1"
      run := do
        let waiting ← waitForCondition "the operator reports the first-build wait" 180 do
          return containsSubstr (← opLog) "WAITING for the first-build approval"
        if !waiting then return .fail "the operator did not report that it waits for the first-build approval"
        -- minutes with no approval, the flared pods meanwhile retrying
        IO.sleep 240000
        let ops ← restartsOf s!"app={cfg.operatorName}"
        let flared ← restartsOf s!"cluster={cfg.name}"
        IO.eprintln s!"# restarts: operator {ops}, flared {flared}"
        if ops.isEmpty || ops.any (·.2 > 0) then return .fail s!"the operator restarted (or is missing) while waiting: {ops}"
        -- the StatefulSet creates its pods in order, the next one only once the
        -- previous is Ready: while the first build waits, only the first pod exists
        if flared.isEmpty then return .fail s!"precondition: expected at least one flared pod, saw none"
        if flared.any (·.2 > 0) then return .fail s!"a flared pod restarted while the operator waited: {flared}"
        let logs ← opLog 5000
        if containsSubstr logs "starting fresh" then return .fail "the operator started fresh without an approval"
        if (← nodeMapExists) then return .fail "a node map was written while waiting"
        let sync := parseNodeSync (← operatorTcpCmd cfg.debugPod ns cfg.operatorName cfg.operatorPort "node sync")
        if !sync.isEmpty then return .fail s!"the operator served an index while waiting: {sync.length} entries"
        -- the Lease is still held by the (only) operator pod and was renewed lately
        let holder := ((← kubectlGetJsonpath "lease" leaseName ns "{.spec.holderIdentity}").toOption.getD "")
        let pods ← getPodNames s!"app={cfg.operatorName}" ns
        IO.eprintln s!"# Lease holder [{holder}], operator pods {pods}"
        if holder.isEmpty || !pods.contains holder then return .fail "the operator does not hold the Lease while it waits"
        let gauge ← waitingGauge
        IO.eprintln s!"# gauge: {gauge}"
        match gauge with
        | some l => if !(l.trim.endsWith " 1" || l.trim.endsWith " 1.0") then return .fail s!"the waiting gauge is not 1: {l}"
        | none => return .fail "the waiting gauge could not be read"
        return .pass },

    { name := "an approval with a WRONG uid changes nothing: still waiting, no restart, no fresh start"
      run := do
        discard <| kubectl ["annotate", "flarecluster", cfg.name, "-n", ns, "--overwrite", "flare.gree.net/first-build-approved=00000000-0000-0000-0000-000000000000"]
        IO.sleep 60000
        let ops ← restartsOf s!"app={cfg.operatorName}"
        let flared ← restartsOf s!"cluster={cfg.name}"
        if ops.any (·.2 > 0) || flared.any (·.2 > 0) then return .fail s!"a restart after the wrong-uid approval: operator {ops}, flared {flared}"
        if containsSubstr (← opLog 5000) "starting fresh" then return .fail "a wrong-uid approval started a fresh build"
        if (← nodeMapExists) then return .fail "a node map was written after a wrong-uid approval"
        return .pass },

    { name := "the approval with the FlareCluster's own uid lets the cluster build, still without a restart"
      run := do
        approveFirstBuild cfg
        let built ← waitForCondition "partition 0 has an Active master and an Active slave" 300 do
          let es := parseNodeSync (← operatorTcpCmd cfg.debugPod ns cfg.operatorName cfg.operatorPort "node sync")
          let p0 := es.filter (·.partition == 0)
          return p0.any (fun e => e.role == 0 && e.state == 0) && p0.any (fun e => e.role == 1 && e.state == 0)
        let logs ← opLog 5000
        let ops ← restartsOf s!"app={cfg.operatorName}"
        let flared ← restartsOf s!"cluster={cfg.name}"
        IO.eprintln s!"# after approval: built={built} restarts operator {ops}, flared {flared}"
        if !built then return .fail "the cluster did not build after the approval"
        if !containsSubstr logs "first build APPROVED" then return .fail "the operator did not log the approved first build"
        if !containsSubstr logs "first-build wait ended" then return .fail "the operator did not log the end of the wait"
        if ops.any (·.2 > 0) then return .fail s!"the operator restarted: {ops}"
        if flared.any (·.2 > 0) then return .fail s!"a flared pod restarted: {flared}"
        let consumed ← waitForCondition "the approval is consumed" 120 do
          return ((← kubectlGetJsonpath "flarecluster" cfg.name ns annotation).toOption.getD "x").trim.isEmpty
        if !consumed then return .fail "the approval was not consumed after the map was persisted"
        match ← waitingGauge with
        | some l => if !(l.trim.endsWith " 0" || l.trim.endsWith " 0.0") then return .fail s!"the waiting gauge did not return to 0: {l}"
        | none => pure ()
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.FirstBuildWait
