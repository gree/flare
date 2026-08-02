/-
  E2E/Tests/OperatorRestart.lean - the control plane itself dies

  The operator persists its node map in the {cr}-node-map ConfigMap and is
  supposed to reload it on restart, but no suite ever killed the operator.
  This one does: verify the cluster keeps its shape across an operator
  restart (state reload, no churn), and that failover still works AFTER the
  restart (the reloaded state is live, not just cosmetic).

  Timing note: a freshly restarted operator has a new 120s startup grace
  during which dead detection is off — the post-restart failover assertion
  waits it out.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.OperatorRestart

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "op-restart"
  «namespace» := "flare-op-restart"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-op-restart"
}

private def numPods : Nat := cfg.partitions * cfg.replicas

private def nodeView : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return parseNodeSync sync

/-- Sorted "fqdn:role:partition" signature of all Master entries — the
    cluster shape we expect to survive an operator restart. -/
private def masterSignature (entries : List NodeSyncEntry) : List String :=
  entries.filter (fun e => e.role == 0 && e.state == 0)
    |>.map (fun e => s!"{e.fqdn}:{e.role}:{e.partition}")
    |>.mergeSort (· ≤ ·)

def suite : TestSuite := {
  name := "operator-restart"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  teardown := cleanupCluster cfg
  tests := [
    -- One test carries the whole restart flow so the pre-restart signature
    -- stays a plain let (no cross-test mutable state).
    { name := "cluster shape survives an operator restart (state reload)"
      run := do
        let before := masterSignature (← nodeView)
        if before.length != 2 then
          return .fail s!"expected 2 masters before restart, got {before}"
        IO.eprintln s!"# masters before restart: {before}"
        match ← kubectl ["delete", "pod", "-n", cfg.«namespace»,
                          "-l", "app=flare-operator", "--force", "--grace-period=0"] with
        | .error e => return .fail s!"operator pod delete failed: {e}"
        | .ok _ =>
          -- wait for the replacement operator to serve node sync again
          let back ← waitForCondition "operator back and serving node sync" 120 do
            return (← nodeView).length ≥ numPods
          if !back then
            return .fail "restarted operator did not serve a full node sync within 120s"
          -- shape must be reloaded from the ConfigMap, not rebuilt by churn:
          -- sample twice to catch late reassignment
          let after1 := masterSignature (← nodeView)
          IO.sleep 15000
          let after2 := masterSignature (← nodeView)
          IO.eprintln s!"# masters after restart: {after1} / {after2}"
          if after1 == before && after2 == before then return .pass
          else return .fail s!"cluster shape changed across operator restart: before={before} after={after1}/{after2} — ConfigMap reload is not preserving assignments" },

    { name := "writes still served after operator restart"
      run := do
        match (← nodeView).find? (fun e => e.role == 0 && e.state == 0 && e.partition == 0) with
        | none => return .fail "no P0 master after restart"
        | some m =>
          let pod := (m.fqdn.splitOn ".").headD m.fqdn
          match ← getPodIp pod cfg.«namespace» with
          | none => return .fail s!"no IP for {pod}"
          | some ip =>
            if ← memcachedSet cfg.debugPod cfg.«namespace» ip cfg.flarePort "opr_key" "opr_val" then
              return .pass
            else return .fail "SET failed via P0 master after operator restart" },

    -- The reloaded state must be LIVE: failover still works. The restarted
    -- operator sits in a fresh 120s dead-detection grace, so wait it out
    -- before killing the master and allow detection+promotion time after.
    { name := "failover still works after the restart (reloaded state is live)"
      run := do
        IO.sleep 125000
        match (← nodeView).find? (fun e => e.role == 0 && e.state == 0 && e.partition == 0) with
        | none => return .fail "no P0 master before kill"
        | some m =>
          let oldPod := (m.fqdn.splitOn ".").headD m.fqdn
          let _ ← kubectl ["delete", "pod", oldPod, "-n", cfg.«namespace»,
                           "--force", "--grace-period=0"]
          let recovered ← waitForCondition "P0 master available after kill" 180 do
            match (← nodeView).find? (fun e => e.role == 0 && e.state == 0 && e.partition == 0) with
            | none => return false
            | some _ =>
              match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                        "{.status.readyReplicas}" with
              | .ok val => return (val.toNat?.getD 0 >= numPods)
              | .error _ => return false
          if recovered then return .pass
          else return .fail "no P0 master re-established within 180s after post-restart kill" }
  ]
}

end FlareOperator.E2E.Tests.OperatorRestart
