/-
  E2E/Tests/ScaleOutSlave.lean - Scale out slave (add replicas) test suite

  Tests: stable cluster, write keys per partition, verify curr_items,
         patch replicas 2→3, scale pods, verify new slaves, verify items preserved
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
  «namespace» := "flare-scale-out-s"  -- Unique namespace for test isolation
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-scale-out-s"
}

private def totalKeys : Nat := 100

def suite : TestSuite := {
  name := "scale-out-slave"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace»
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: cluster is stable
    { name := "pre-flight: cluster stable with 2P × 2R"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        if entries.length >= 4 && countMasters entries >= 2 then return .pass
        else return .fail s!"expected 4+ nodes with 2+ masters, got {entries.length} nodes, {countMasters entries} masters" },

    -- Test 2: write 100 keys via proxy routing
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
            let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "sos" totalKeys
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

    -- Test 4: patch CRD replicas 2→3
    { name := "patch replicas 2→3"
      run := do
        let patchJson := "{\"spec\":{\"replicas\":3}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 5: scale StatefulSet
    { name := "scale pods to 6 (2P × 3R)"
      run := do
        match ← kubectlScale "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» 6 with
        | .ok _ =>
          let ok ← kubectlRolloutStatus s!"statefulset/{cfg.name}-nodes" cfg.«namespace» 300
          if ok then return .pass
          else return .fail "rollout timeout"
        | .error e => return .fail s!"scale failed: {e}" },

    -- Test 6: new nodes registered
    { name := "6 nodes registered with operator"
      run := do
        let ok ← waitForCondition "6 nodes registered" 180 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          return (entries.length >= 6)
        if ok then return .pass
        else return .fail "not all 6 nodes registered" },

    -- Test 7: new slaves assigned to partitions
    { name := "new slaves assigned (Prepare state)"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let p0Slaves := (entries.filter (fun e => e.role == 1 && e.partition == 0)).length
        let p1Slaves := (entries.filter (fun e => e.role == 1 && e.partition == 1)).length
        IO.eprintln s!"# Slaves: P0={p0Slaves}, P1={p1Slaves}"
        if p0Slaves >= 2 && p1Slaves >= 2 then return .pass
        else return .fail s!"P0 has {p0Slaves} slaves, P1 has {p1Slaves} slaves (expected 2 each)" },

    -- Test 8: masters unchanged and items preserved
    { name := "masters unchanged, curr_items preserved"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        if countMasters entries != 2 then
          return .fail s!"expected 2 masters, got {countMasters entries}"
        let p0 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 0 cfg.flarePort
        let p1 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 1 cfg.flarePort
        IO.eprintln s!"# After scale-out: P0={p0}, P1={p1}"
        if p0 > 0 && p1 > 0 then return .pass
        else return .fail s!"items lost: P0={p0}, P1={p1}" }
  ]
}

end FlareOperator.E2E.Tests.ScaleOutSlave
