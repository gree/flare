/-
  E2E/Tests/FirstBuildExistingCluster.lean — negative test of the first-build
  wait: an EXISTING cluster whose operator is away behaves as before.

  The first-build wait is limited to one explicit signal: while a NEW cluster
  waits for the first-build approval the operator answers every request on its
  index port with `SERVER_ERROR first_build_approval_pending`, and only that
  answer makes flared wait. An existing cluster (built, serving, node map
  present) must not get there:

  - while its operator is scaled to 0 a restarted flared gets a refused
    connection (no pending answer), does not wait for a first build and
    exits as before (the container restarts);
  - the operator that returns has a node map: it serves it and never answers
    with the pending signal (no map is written afresh, no first-build wait);
  - everything recovers: all pods Ready, the keys written before are intact.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.FirstBuildExistingCluster

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "fb-exist"
  «namespace» := "flare-fb-exist"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-fb-exist"
  storageBackend := "rocksdb"
}

private def ns : String := cfg.«namespace»
private def pendingAnswer : String := "SERVER_ERROR first_build_approval_pending"
private def numPods : Nat := cfg.partitions * cfg.replicas

private def nodeView : IO (List NodeSyncEntry) :=
  return parseNodeSync (← operatorTcpCmd cfg.debugPod ns cfg.operatorName cfg.operatorPort "node sync")

private def nodeMapExists : IO Bool := do
  return (← kubectlGetJsonpath "configmap" s!"{cfg.name}-node-map" ns "{.metadata.name}").toOption.isSome

private def opLog (tail : Nat := 3000) : IO String :=
  kubectlLogsLabel s!"app={cfg.operatorName}" ns tail

private def restartCount (pod : String) : IO Nat := do
  let v := ((← kubectlGetJsonpath "pod" pod ns "{.status.containerStatuses[0].restartCount}").toOption.getD "")
  return v.toNat?.getD 0

private def allReady : IO Bool := do
  match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" ns "{.status.readyReplicas}" with
  | .ok v => return v.toNat?.getD 0 ≥ numPods
  | .error _ => return false

private def keyCount : Nat := 20

def suite : TestSuite := {
  name := "first-build-existing-cluster"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      throw (IO.userError "cluster did not stabilize")
  teardown := cleanupCluster cfg
  onFailure := dumpClusterDiagnostics ns s!"app={cfg.operatorName}"
  tests := [
    { name := "the existing cluster has a node map and its operator does not give the pending answer"
      run := do
        if !(← nodeMapExists) then return .fail "precondition: the built cluster has no node map"
        for cmd in ["node sync", "meta"] do
          let raw := (← operatorTcpCmd cfg.debugPod ns cfg.operatorName cfg.operatorPort cmd).trim
          IO.eprintln s!"# '{cmd}' on the existing cluster: [{raw.take 120}]"
          if containsSubstr raw "first_build_approval_pending" then
            return .fail s!"an operator with a node map gave the first-build pending answer to '{cmd}'"
        if (← nodeView).length < numPods then return .fail "precondition: the operator does not serve the full node map"
        if containsSubstr (← opLog 5000) "WAITING for the first-build approval" then
          return .fail "an operator with a node map reported a first-build wait"
        -- data to be found again after the recovery
        match (← nodeView).find? (fun e => e.role == 0 && e.state == 0 && e.partition == 0) with
        | none => return .fail "no P0 master"
        | some m =>
          let pod := (m.fqdn.splitOn ".").headD m.fqdn
          match ← getPodIp pod ns with
          | none => return .fail s!"no IP for {pod}"
          | some ip =>
            let stored ← writeKeys cfg.debugPod ns ip cfg.flarePort "fbx" keyCount
            if stored != keyCount then return .fail s!"only {stored}/{keyCount} keys stored"
            return .pass },

    { name := "operator away: a restarted flared gets a refused connection, does not wait for a first build and exits as before"
      run := do
        match ← kubectlScale "deployment" cfg.operatorName ns 0 with
        | .error e => return .fail s!"scaling the operator to 0 failed: {e}"
        | .ok _ => pure ()
        let gone ← waitForCondition "the operator pod is gone" 120 do
          return (← getPodNames s!"app={cfg.operatorName}" ns).isEmpty
        if !gone then return .fail "the operator pod did not go away"
        -- restart the SLAVE (the master keeps serving); the replacement flared
        -- starts with no operator to talk to
        let entries ← nodeView
        let pods ← getPodNames s!"cluster={cfg.name}" ns
        let slave := (entries.find? (fun e => e.role == 1 && e.partition == 0)).map
          (fun e => (e.fqdn.splitOn ".").headD e.fqdn)
        let victim := slave.getD (pods.getLastD "")
        if victim.isEmpty then return .fail "no flared pod to restart"
        let uid0 := ((← kubectlGetJsonpath "pod" victim ns "{.metadata.uid}").toOption.getD "")
        discard <| kubectl ["delete", "pod", victim, "-n", ns, "--wait=false"]
        let back ← waitForCondition "the replacement flared pod exists" 120 do
          let u := ((← kubectlGetJsonpath "pod" victim ns "{.metadata.uid}").toOption.getD "")
          return !u.isEmpty && u != uid0
        if !back then return .fail "the flared pod was not recreated"
        -- as before: the flared container exits on its own (restart), it is not
        -- parked in the first-build wait
        let exited ← waitForCondition "the flared container exits and is restarted" 180 do
          return (← restartCount victim) ≥ 1
        let rc ← restartCount victim
        let flog ← kubectlLogsLabel s!"cluster={cfg.name}" ns 400
        IO.eprintln s!"# {victim}: restarts {rc} while the operator is away"
        if !exited then return .fail s!"the restarted flared did not exit while the operator is away (restarts {rc}): it waits as for a first build"
        if containsSubstr flog "waits for the first-build approval" then
          return .fail "a flared of an existing cluster reported a first-build wait"
        if (← allReady) then return .fail "all pods are Ready although a flared has no operator"
        return .pass },

    { name := "operator back: all pods Ready, keys intact, no pending answer, no fresh build"
      run := do
        match ← kubectlScale "deployment" cfg.operatorName ns 1 with
        | .error e => return .fail s!"scaling the operator to 1 failed: {e}"
        | .ok _ => pure ()
        let served ← waitForCondition "the operator serves the full node map again" 180 do
          return (← nodeView).length ≥ numPods
        if !served then return .fail "the returned operator did not serve the node map"
        let ready ← waitForCondition "all pods are Ready" 420 do allReady
        if !ready then return .fail "not all pods are Ready after the operator returned"
        for cmd in ["node sync", "meta"] do
          let raw := (← operatorTcpCmd cfg.debugPod ns cfg.operatorName cfg.operatorPort cmd).trim
          if containsSubstr raw "first_build_approval_pending" then
            return .fail s!"the returned operator (node map present) gave the pending answer to '{cmd}'"
        let logs ← opLog 5000
        if containsSubstr logs "WAITING for the first-build approval" then
          return .fail "the returned operator waited for a first-build approval"
        if containsSubstr logs "starting fresh" then
          return .fail "the returned operator started a fresh build over an existing cluster"
        if !(← nodeMapExists) then return .fail "the node map is gone"
        -- keys intact
        match (← nodeView).find? (fun e => e.role == 0 && e.state == 0 && e.partition == 0) with
        | none => return .fail "no P0 master after recovery"
        | some m =>
          let pod := (m.fqdn.splitOn ".").headD m.fqdn
          match ← getPodIp pod ns with
          | none => return .fail s!"no IP for {pod}"
          | some ip =>
            let mut missing : List Nat := []
            for i in [0:keyCount] do
              let v ← memcachedGet cfg.debugPod ns ip cfg.flarePort s!"fbx_{i}"
              if v != some s!"val_{i}" then missing := i :: missing
            if !missing.isEmpty then return .fail s!"keys lost or changed after the recovery: {missing.reverse}"
            return .pass }
  ]
}

end FlareOperator.E2E.Tests.FirstBuildExistingCluster
