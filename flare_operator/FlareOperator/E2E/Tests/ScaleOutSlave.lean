/-
  E2E/Tests/ScaleOutSlave.lean - Scale out slave (add replicas) test suite

  Tests: stable cluster, patch replicas 2→3, scale pods, verify new slaves in Prepare
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ScaleOutSlave

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfg : ClusterConfig := {
  name := "scale-out-slave"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-scale-out-s"
}

def suite : TestSuite := {
  name := "scale-out-slave"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "cluster did not stabilize")
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: cluster is stable
    { name := "pre-flight: cluster stable with 2 partitions, 2 replicas"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        if entries.length >= 4 && countMasters entries >= 2 then return .pass
        else return .fail s!"expected 4+ nodes with 2+ masters, got {entries.length} nodes, {countMasters entries} masters" },

    -- Test 2: patch CRD replicas 2→3
    { name := "patch replicas 2→3"
      run := do
        let patchJson := "{\"spec\":{\"replicas\":3}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 3: scale StatefulSet
    { name := "scale pods to 6 (2 partitions × 3 replicas)"
      run := do
        match ← kubectlScale "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» 6 with
        | .ok _ =>
          let ok ← kubectlRolloutStatus s!"statefulset/{cfg.name}-nodes" cfg.«namespace» 300
          if ok then return .pass
          else return .fail "rollout timeout"
        | .error e => return .fail s!"scale failed: {e}" },

    -- Test 4: new nodes registered
    { name := "6 nodes registered with operator"
      run := do
        IO.sleep 60000
        let ok ← waitForCondition "6 nodes registered" 120 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          return (entries.length >= 6)
        if ok then return .pass
        else return .fail "not all 6 nodes registered" },

    -- Test 5: new slaves assigned to partitions
    { name := "new slaves assigned (Prepare state)"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        -- Count slaves per partition (including Prepare state=1)
        let p0Slaves := (entries.filter (fun e => e.role == 1 && e.partition == 0)).length
        let p1Slaves := (entries.filter (fun e => e.role == 1 && e.partition == 1)).length
        if p0Slaves >= 2 && p1Slaves >= 2 then return .pass
        else return .fail s!"P0 has {p0Slaves} slaves, P1 has {p1Slaves} slaves (expected 2 each)" },

    -- Test 6: masters unchanged
    { name := "masters unchanged after scale-out"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        if countMasters entries == 2 then return .pass
        else return .fail s!"expected 2 masters, got {countMasters entries}" }
  ]
}

end FlareOperator.E2E.Tests.ScaleOutSlave
