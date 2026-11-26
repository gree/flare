/-
  E2E/Tests/FirstBuildWait.lean — a new cluster's first build waits for the
  first-build approval without a restart.

  Before: with no node map, an unobservable past and no approval the operator
  retried 12 times and exited (CrashLoopBackOff), and every flared exited
  because the operator did not serve its index yet. Now the operator keeps
  its Lease and waits (no index, no map), and while it waits its index port
  answers every request with `SERVER_ERROR first_build_approval_pending`:
  the explicit signal on which flared waits and retries (nothing else makes
  it wait: see first-build-existing-cluster). The approval can come any time
  after the FlareCluster exists.

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
  -- long on purpose: a flared that ignores SIGTERM while it waits would only
  -- go at this grace period (SIGKILL), which the deletion test tells apart
  terminationGraceSeconds := 90
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

/-- seconds since the Lease was last renewed (its renewTime), as the API
    holds it -/
private def leaseRenewAge : IO (Option Nat) := do
  match ← kubectlGetJsonpath "lease" leaseName ns "{.spec.renewTime}" with
  | .error _ => return none
  | .ok t =>
    if t.isEmpty then return none
    let r ← IO.Process.output { cmd := "date", args := #["-d", t, "+%s"] }
    let n ← IO.Process.output { cmd := "date", args := #["+%s"] }
    match r.stdout.trim.toNat?, n.stdout.trim.toNat? with
    | some a, some b => return some (if b ≥ a then b - a else 0)
    | _, _ => return none

private def leaseTransitions : IO String :=
  return ((← kubectlGetJsonpath "lease" leaseName ns "{.spec.leaseTransitions}").toOption.getD "")

private def conditionPath (field : String) : String :=
  "{.status.conditions[?(@.type==\"FirstBuildApproval\")]." ++ field ++ "}"

private def operatorReady : IO String := do
  match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app={cfg.operatorName}", "-o",
      "jsonpath={.items[0].status.conditions[?(@.type==\"Ready\")].status}"] with
  | .ok o => return o.trim
  | .error _ => return ""

def suite : TestSuite := {
  name := "first-build-wait"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    -- the CR and the StatefulSet, deliberately WITHOUT the approval
    deployDeferredCluster cfg false (afterOperatorWaits := true)
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
        -- the index port answers the explicit signal to every request and serves nothing
        for cmd in ["node sync", "node add flare-x 12121", "meta"] do
          let raw := (← operatorTcpCmd cfg.debugPod ns cfg.operatorName cfg.operatorPort cmd).trim
          IO.eprintln s!"# '{cmd}' while waiting: [{raw}]"
          if raw != "SERVER_ERROR first_build_approval_pending" then
            return .fail s!"'{cmd}' was not answered with exactly the pending signal: [{raw}]"
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
        | some l => if !(l.trim.endsWith " 1" || l.trim.endsWith " 1.0" || l.trim.endsWith " 1.000000") then return .fail s!"the waiting gauge is not 1: {l}"
        | none => return .fail "the waiting gauge could not be read"
        -- the status condition of the Issue goal: present while waiting, naming the annotation and the UID
        let uid := ((← kubectlGetJsonpath "flarecluster" cfg.name ns "{.metadata.uid}").toOption.getD "")
        let cStatus := ((← kubectlGetJsonpath "flarecluster" cfg.name ns (conditionPath "status")).toOption.getD "")
        let cMsg := ((← kubectlGetJsonpath "flarecluster" cfg.name ns (conditionPath "message")).toOption.getD "")
        IO.eprintln s!"# condition FirstBuildApproval={cStatus}: {cMsg}"
        if cStatus != "Required" then return .fail s!"the FirstBuildApproval condition is not Required while waiting: [{cStatus}]"
        if uid.isEmpty || !containsSubstr cMsg uid || !containsSubstr cMsg "flare.gree.net/first-build-approved" then
          return .fail s!"the condition message does not name the annotation and the UID: {cMsg}"
        -- the operator is Ready while it waits: its port answers (the Service routes
        -- only to Ready pods, so flared can receive the signal)
        let ready ← operatorReady
        IO.eprintln s!"# operator Ready: [{ready}]"
        if ready != "True" then return .fail s!"the operator is not Ready while it announces the wait: [{ready}]"
        -- flared is waiting on the signal, not retrying blindly
        let flog ← kubectlLogsLabel s!"cluster={cfg.name}" ns 200
        if !containsSubstr flog "waits for the first-build approval" then
          return .fail "flared does not report that the operator waits for the first-build approval"
        -- the Lease is renewed ON TIME, not merely named: a fresh renewTime that moves
        let age1 ← leaseRenewAge
        IO.sleep 9000
        let age2 ← leaseRenewAge
        IO.eprintln s!"# renew age: {age1} then {age2} (the lease lasts 15 s)"
        match age1, age2 with
        | some a, some b => if a > 14 || b > 14 then return .fail s!"the Lease renewTime is stale while waiting ({a} s, {b} s)"
        | _, _ => return .fail "the Lease renewTime could not be read"
        return .pass },

    { name := "deleting a waiting flared pod ends it promptly (SIGTERM), not at the grace period (SIGKILL)"
      run := do
        let pods ← getPodNames s!"cluster={cfg.name}" ns
        match pods with
        | [] => return .fail "no flared pod to delete"
        | pod :: _ =>
          let uid0 := ((← kubectlGetJsonpath "pod" pod ns "{.metadata.uid}").toOption.getD "")
          let t0 ← IO.monoMsNow
          discard <| kubectl ["delete", "pod", pod, "-n", ns, "--wait=false"]
          -- the exit code of the stopped container, if it can still be seen
          let mut lastExit := ""
          let mut gone := false
          for _ in [0:300] do
            let cur := ((← kubectlGetJsonpath "pod" pod ns "{.metadata.uid}").toOption.getD "")
            if cur != uid0 then
              gone := true
              break
            let ec := ((← kubectlGetJsonpath "pod" pod ns "{.status.containerStatuses[0].state.terminated.exitCode}").toOption.getD "")
            if !ec.isEmpty then lastExit := ec
            IO.sleep 200
          let dt := ((← IO.monoMsNow) - t0) / 1000
          IO.eprintln s!"# the waiting flared pod was gone after {dt} s (grace {cfg.terminationGraceSeconds} s), exit code seen [{lastExit}]"
          if !gone then return .fail "the deleted waiting flared pod did not go within 60 s"
          if dt > 20 then return .fail s!"the waiting flared pod needed {dt} s to stop: it does not end its first-connection wait on SIGTERM"
          if lastExit == "137" then return .fail "the waiting flared container was killed (137), not stopped by SIGTERM"
          -- the StatefulSet's replacement waits again (a clean container, no restart)
          let back ← waitForCondition "the replacement flared pod exists" 120 do
            return (← getPodNames s!"cluster={cfg.name}" ns).contains pod
          if !back then return .fail "the flared pod was not recreated"
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
        let transitions0 ← leaseTransitions
        let holder0 := ((← kubectlGetJsonpath "lease" leaseName ns "{.spec.holderIdentity}").toOption.getD "")
        approveFirstBuild cfg
        -- across the wait -> normal loop transition: sample the Lease's renewTime
        -- all along; it must never be older than the 15 s lease
        let worst ← IO.mkRef (0 : Nat)
        let samples ← IO.mkRef (0 : Nat)
        let built ← waitForCondition "partition 0 has an Active master and an Active slave" 300 do
          match ← leaseRenewAge with
          | some a =>
            worst.modify (max a)
            samples.modify (· + 1)
          | none => pure ()
          let es := parseNodeSync (← operatorTcpCmd cfg.debugPod ns cfg.operatorName cfg.operatorPort "node sync")
          let p0 := es.filter (·.partition == 0)
          return p0.any (fun e => e.role == 0 && e.state == 0) && p0.any (fun e => e.role == 1 && e.state == 0)
        IO.eprintln s!"# Lease renewTime across the transition: oldest age {← worst.get} s in {← samples.get} samples (lease 15 s)"
        if (← worst.get) > 14 then return .fail s!"the Lease went {← worst.get} s without a renew across the wait -> normal loop handoff"
        if (← leaseTransitions) != transitions0 then return .fail s!"the Lease changed hands (transitions {transitions0} -> {← leaseTransitions})"
        if ((← kubectlGetJsonpath "lease" leaseName ns "{.spec.holderIdentity}").toOption.getD "") != holder0 then
          return .fail "the Lease holder changed across the transition"
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
        let cleared ← waitForCondition "the FirstBuildApproval condition is cleared" 60 do
          return ((← kubectlGetJsonpath "flarecluster" cfg.name ns (conditionPath "status")).toOption.getD "x").trim.isEmpty
        if !cleared then return .fail "the FirstBuildApproval condition is still set after the approval"
        if (← operatorReady) != "True" then
          let rdy ← waitForCondition "the operator becomes Ready" 120 do return (← operatorReady) == "True"
          if !rdy then return .fail "the operator is not Ready after the approval"
        match ← waitingGauge with
        | some l => if !(l.trim.endsWith " 0" || l.trim.endsWith " 0.0" || l.trim.endsWith " 0.000000") then return .fail s!"the waiting gauge did not return to 0: {l}"
        | none => pure ()
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.FirstBuildWait
