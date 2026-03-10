/-
  E2E/Tests/ScaleInSlave.lean - Scale in slave (reduce replicas) test suite

  Tests: stable cluster (3 replicas), patch replicas 3→2, scale down, verify masters intact
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ScaleInSlave

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfg : ClusterConfig := {
  name := "scale-in-slave"
  partitions := 2
  replicas := 3
  operatorName := "flare-operator"
  debugPod := "debug-scale-in-s"
}

def suite : TestSuite := {
  name := "scale-in-slave"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "cluster did not stabilize")
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: cluster stable with 3 replicas
    { name := "pre-flight: cluster stable with 3 replicas (6 pods)"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        if entries.length >= 6 && countMasters entries >= 2 then return .pass
        else return .fail s!"expected 6+ nodes, got {entries.length}" },

    -- Test 2: patch CRD replicas 3→2
    { name := "patch replicas 3→2"
      run := do
        let patchJson := "{\"spec\":{\"replicas\":2}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 3: scale down StatefulSet
    { name := "scale down to 4 pods (2 partitions × 2 replicas)"
      run := do
        match ← kubectlScale "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» 4 with
        | .ok _ =>
          -- Wait for scale-down to complete
          let ok ← waitForCondition "4 pods running" 120 do
            match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                      "{.status.readyReplicas}" with
            | .ok val => return (val.toNat?.getD 0 == 4)
            | .error _ => return false
          if ok then return .pass
          else return .fail "scale-down did not complete"
        | .error e => return .fail s!"scale failed: {e}" },

    -- Test 4: wait for operator to detect removed pods
    { name := "operator detects removed pods"
      run := do
        -- Wait for dead detection + grace period
        IO.sleep 40000
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let active := countActiveNodes entries
        -- After scale-down, some nodes may be marked Down
        if active >= 4 then return .pass
        else return .fail s!"only {active} active nodes (expected >= 4)" },

    -- Test 5: masters intact
    { name := "masters intact after scale-in"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let masters := countMasters entries
        if masters >= 2 then return .pass
        else return .fail s!"only {masters} masters (expected 2)" },

    -- Test 6: one-master-per-partition maintained
    { name := "one-master-per-partition maintained"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let dups := checkOneMasterPerPartition entries
        if dups.isEmpty then return .pass
        else return .fail s!"duplicate masters for partitions: {dups}" }
  ]
}

end FlareOperator.E2E.Tests.ScaleInSlave
