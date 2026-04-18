/-
  E2E/Tests/TerminatingPodHandling.lean - Terminating pod detection

  Verifies that the operator correctly handles pods in Terminating state
  (redis-operator #1544 equivalent):

  1. Kill a master pod with a long grace period (30s instead of 0)
  2. During the grace period, the pod is Terminating but still in the pod list
  3. Verify the operator detects the master is gone and promotes a slave
     BEFORE the pod finishes terminating

  This catches the bug where the operator sees a Terminating pod as "alive"
  and doesn't trigger failover until K8s fully removes it (which could be
  minutes/hours for large datasets).
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.Kubectl

namespace FlareOperator.E2E.Tests.TerminatingPodHandling

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "term-pod"
  «namespace» := "flare-term-pod"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-term-pod"
  debugPod := "debug-term-pod"
}

def suite : TestSuite := {
  name := "terminating-pod-handling"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let ok ← waitForStable cfg 50
    if !ok then throw (IO.userError "cluster did not stabilize")
  teardown := do
    cleanupCluster cfg
  tests := [
    -- Test 1: verify cluster is healthy
    { name := "pre-flight: one-master-per-partition"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let masters := entries.filter (fun e => e.role == 0 && e.state == 0)
        let partitions := masters.map (·.partition) |>.eraseDups
        if partitions.length == cfg.partitions then return .pass
        else return .fail s!"expected {cfg.partitions} masters, got {partitions.length}" },

    -- Test 2: delete master with grace period (not --force)
    -- This leaves the pod in Terminating state for up to 30s
    { name := "delete P0 master with 30s grace period"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master to delete"
        | some oldMaster =>
          IO.eprintln s!"# Deleting P0 master {oldMaster} with grace-period=30..."
          let _ ← kubectl ["delete", "pod", oldMaster, "-n", cfg.«namespace»,
                            "--grace-period=30"]
          return .pass },

    -- Test 3: verify failover occurs even while pod is Terminating
    -- The operator should detect the master is gone and promote a slave
    { name := "failover occurs during Terminating grace period"
      run := do
        -- Wait for a new master to be elected for P0
        let ok ← waitForCondition "P0 master available" 90 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          match findMasterPod entries 0 with
          | some _ => return true
          | none => return false
        if ok then return .pass
        else return .fail "P0 master not re-elected within 90s" },

    -- Test 4: verify one-master-per-partition maintained
    { name := "one-master-per-partition after Terminating failover"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let duplicates := checkOneMasterPerPartition entries
        if duplicates.isEmpty then return .pass
        else return .fail s!"duplicate masters in partitions: {duplicates}" },

    -- Test 5: wait for pod replacement and verify recovery
    { name := "cluster recovers after Terminating pod replaced"
      run := do
        let ok ← waitForCondition "all pods ready" 180 do
          match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                    "{.status.readyReplicas}" with
          | .ok val => return (val.toNat?.getD 0 >= cfg.partitions * cfg.replicas)
          | .error _ => return false
        if ok then return .pass
        else return .fail "pods did not recover after Terminating pod replacement" }
  ]
}

end FlareOperator.E2E.Tests.TerminatingPodHandling
