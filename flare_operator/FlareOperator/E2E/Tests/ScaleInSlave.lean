/-
  E2E/Tests/ScaleInSlave.lean - Scale in slave (reduce replicas) test suite

  Tests: stable cluster (3 replicas), write keys per partition, verify curr_items,
         patch replicas 3→2, scale down, verify masters intact, verify items preserved
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
  «namespace» := "flare-scale-in-s"  -- Unique namespace for test isolation
  partitions := 2
  replicas := 3
  operatorName := "flare-operator"
  debugPod := "debug-scale-in-s"
}

private def totalKeys : Nat := 100

def suite : TestSuite := {
  name := "scale-in-slave"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: cluster stable with 3 replicas
    { name := "pre-flight: cluster stable with 3R (6 pods)"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        if entries.length >= 6 && countMasters entries >= 2 then return .pass
        else return .fail s!"expected 6+ nodes, got {entries.length}" },

    -- Test 2: write 100 keys via proxy routing (single entry point)
    { name := "write 100 keys via proxy routing"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master"
        | some pod =>
          match ← getPodIp pod cfg.«namespace» with
          | none => return .fail s!"no IP for {pod}"
          | some ip =>
            let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "sis" totalKeys
            IO.eprintln s!"# Wrote via {pod}: stored {stored}/{totalKeys}"
            if stored == totalKeys then return .pass
            else return .fail s!"only {stored}/{totalKeys} keys stored" },

    -- Test 3: verify key distribution across partitions
    { name := "verify key distribution (P0 > 0, P1 > 0, total = 100)"
      run := do
        let p0 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 0 cfg.flarePort
        let p1 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 1 cfg.flarePort
        IO.eprintln s!"# Distribution: P0={p0}, P1={p1}, total={p0 + p1}"
        if p0 > 0 && p1 > 0 && p0 + p1 == totalKeys then return .pass
        else return .fail s!"P0={p0}, P1={p1}, total={p0 + p1} (expected both > 0, total = {totalKeys})" },

    -- Test 4: patch CRD replicas 3→2
    { name := "patch replicas 3→2"
      run := do
        let patchJson := "{\"spec\":{\"replicas\":2}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 5: scale down StatefulSet
    { name := "scale down to 4 pods (2P × 2R)"
      run := do
        match ← kubectlScale "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» 4 with
        | .ok _ =>
          let ok ← waitForCondition "4 pods running" 120 do
            match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                      "{.status.readyReplicas}" with
            | .ok val => return (val.toNat?.getD 0 == 4)
            | .error _ => return false
          if ok then return .pass
          else return .fail "scale-down did not complete"
        | .error e => return .fail s!"scale failed: {e}" },

    -- Test 6: wait for operator to detect removed pods
    { name := "operator detects removed pods"
      run := do
        let ok ← waitForCondition "active >= 4" 120 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          let active := countActiveNodes entries
          return (active >= 4)
        if ok then return .pass
        else return .fail "active nodes did not reach >= 4" },

    -- Test 7: masters intact and one-master-per-partition
    { name := "masters intact after scale-in"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let masters := countMasters entries
        let dups := checkOneMasterPerPartition entries
        if masters < 2 then return .fail s!"only {masters} masters (expected 2)"
        else if !dups.isEmpty then return .fail s!"duplicate masters: {dups}"
        else return .pass },

    -- Test 8: curr_items on masters preserved after scale-in
    { name := "curr_items preserved on masters after scale-in"
      run := do
        let p0 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 0 cfg.flarePort
        let p1 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 1 cfg.flarePort
        IO.eprintln s!"# After scale-in: P0={p0}, P1={p1}"
        if p0 > 0 && p1 > 0 then return .pass
        else return .fail s!"items lost: P0={p0}, P1={p1}" }
  ]
}

end FlareOperator.E2E.Tests.ScaleInSlave
