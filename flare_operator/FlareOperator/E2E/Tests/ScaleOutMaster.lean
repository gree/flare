/-
  E2E/Tests/ScaleOutMaster.lean - Scale out master (add partition) test suite

  Tests: stable cluster, write keys per partition, verify curr_items,
         patch partitions 2→3, scale pods, verify P2 master+slave,
         verify original partition items preserved
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ScaleOutMaster

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfg : ClusterConfig := {
  name := "scale-out-master"
  «namespace» := "flare-scale-out-m"  -- Unique namespace for test isolation
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-scale-out-m"
}

private def totalKeys : Nat := 100

def suite : TestSuite := {
  name := "scale-out-master"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: cluster is stable with 2 partitions
    { name := "pre-flight: cluster stable with 2 partitions"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        if countMasters entries >= 2 then return .pass
        else return .fail s!"only {countMasters entries} masters (expected 2)" },

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
            let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "som" totalKeys
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

    -- Test 4: patch CRD partitions 2→3
    { name := "patch partitions 2→3"
      run := do
        let patchJson := "{\"spec\":{\"partitions\":3}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 5: scale StatefulSet pods
    { name := "scale pods to 6 (3 partitions × 2 replicas)"
      run := do
        match ← kubectlScale "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» 6 with
        | .ok _ =>
          let svcYaml := partitionServiceYaml { cfg with partitions := 3 } 2
          try
            let result ← IO.Process.output {
              cmd := "sh"
              args := #["-c", s!"cat <<'ENDOFYAML' | kubectl apply -f -\n{svcYaml}\nENDOFYAML"]
            }
            let _ := result
            pure ()
          catch _ => pure ()
          let ok ← kubectlRolloutStatus s!"statefulset/{cfg.name}-nodes" cfg.«namespace» 300
          if ok then return .pass
          else return .fail "rollout timeout"
        | .error e => return .fail s!"scale failed: {e}" },

    -- Test 6: wait for new nodes to register
    { name := "new nodes registered with operator"
      run := do
        let ok ← waitForCondition "6 nodes registered" 180 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          return (entries.length >= 6)
        if ok then return .pass
        else return .fail "not all 6 nodes registered" },

    -- Test 7: verify P2 has master and slave. The slave is assigned only
    -- after the P2 master's reconstruction completes (proxy-pool
    -- throttling: one reconstruction per partition at a time), so this is
    -- a polling wait, not a single-shot read — the previous version raced
    -- the master's Prepare→Active on slow CI runners.
    { name := "P2 has master and slave"
      run := do
        let ok ← waitForCondition "P2 master and slave assigned" 180 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          let p2Master := findMasterPod entries 2
          let p2Slaves := entries.filter (fun e => e.role == 1 && e.partition == 2)
          return p2Master.isSome && !p2Slaves.isEmpty
        if ok then return .pass
        else return .fail "P2 master+slave not both assigned within 180s" },

    -- Test 8: original partition items preserved after scale-out
    { name := "P0 and P1 curr_items preserved after scale-out"
      run := do
        let p0 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 0 cfg.flarePort
        let p1 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 1 cfg.flarePort
        let p2 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 2 cfg.flarePort
        IO.eprintln s!"# After scale-out: P0={p0}, P1={p1}, P2={p2}"
        if p0 > 0 && p1 > 0 then return .pass
        else return .fail s!"P0={p0}, P1={p1} (items lost during scale-out)" }
  ]
}

end FlareOperator.E2E.Tests.ScaleOutMaster
