/-
  E2E/Tests/ScaleInMaster.lean - Scale in master (reduce partitions via replication) test suite

  Tests: 2-cluster setup, write keys, enable replication, wait Dumping→Forwarding
  Reducing partitions requires inter-cluster replication to migrate data.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ScaleInMaster

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfgV1 : ClusterConfig := {
  name := "sim-v1"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-sim-v1"
  debugPod := "debug-scale-in-m"
}

private def cfgV2 : ClusterConfig := {
  name := "sim-v2"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator-sim-v2"
  debugPod := "debug-scale-in-m"
}

def suite : TestSuite := {
  name := "scale-in-master"
  setup := do
    cleanupCluster cfgV1
    cleanupCluster cfgV2
    deployCluster cfgV1
    let stable1 ← waitForStable cfgV1 50
    if !stable1 then throw (IO.userError "v1 cluster did not stabilize")
    deploySecondCluster cfgV2
    let stable2 ← waitForStable cfgV2 50
    if !stable2 then throw (IO.userError "v2 cluster did not stabilize")
  teardown := do
    cleanupCluster cfgV1
    cleanupCluster cfgV2
  tests := [
    -- Test 1: both clusters stable
    { name := "pre-flight: both clusters stable"
      run := do
        let sync1 ← operatorTcpCmd cfgV1.debugPod cfgV1.«namespace» cfgV1.operatorName cfgV1.operatorPort "node sync"
        let sync2 ← operatorTcpCmd cfgV2.debugPod cfgV2.«namespace» cfgV2.operatorName cfgV2.operatorPort "node sync"
        let e1 := parseNodeSync sync1
        let e2 := parseNodeSync sync2
        if e1.length >= 4 && e2.length >= 2 then return .pass
        else return .fail s!"v1: {e1.length} nodes, v2: {e2.length} nodes" },

    -- Test 2: write keys to v1
    { name := "write keys to v1"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfgV1.name}" cfgV1.«namespace»
        match ips.head? with
        | none => return .fail "no v1 pod IPs"
        | some ip =>
          let mut stored := 0
          for i in List.range 10 do
            let ok ← memcachedSet cfgV1.debugPod cfgV1.«namespace» ip cfgV1.flarePort
                        s!"sim_key_{i}" s!"sim_val_{i}"
            if ok then stored := stored + 1
          if stored > 0 then return .pass
          else return .fail "no keys stored" },

    -- Test 3: trigger replication from v1 → v2
    { name := "trigger replication v1→v2"
      run := do
        let v2Svc := s!"{cfgV2.name}-nodes.{cfgV2.«namespace»}.svc.cluster.local"
        let patchJson := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{v2Svc}\",\"port\":{cfgV2.flarePort},\"mode\":\"duplicate\",\"concurrency\":2}}}"
        match ← kubectlPatch "flarecluster" cfgV1.name cfgV1.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 4: verify Dumping phase
    { name := "migrationPhase transitions to Dumping"
      run := do
        let ok ← waitForCondition "migrationPhase=Dumping" 60 do
          match ← kubectlGetJsonpath "flarecluster" cfgV1.name cfgV1.«namespace»
                    "{.status.migrationPhase}" with
          | .ok val => return (val == "Dumping")
          | .error _ => return false
        if ok then return .pass
        else return .fail "did not reach Dumping" },

    -- Test 5: verify Forwarding phase (auto transition)
    { name := "migrationPhase transitions to Forwarding"
      run := do
        let ok ← waitForCondition "migrationPhase=Forwarding" 180 do
          match ← kubectlGetJsonpath "flarecluster" cfgV1.name cfgV1.«namespace»
                    "{.status.migrationPhase}" with
          | .ok val => return (val == "Forwarding")
          | .error _ => return false
        if ok then return .pass
        else return .fail "did not reach Forwarding" },

    -- Test 6: v2 cluster has correct partition count
    { name := "v2 has 1 partition with master"
      run := do
        let sync ← operatorTcpCmd cfgV2.debugPod cfgV2.«namespace» cfgV2.operatorName cfgV2.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 0 with
        | some _ => return .pass
        | none => return .fail "v2 has no master for P0" }
  ]
}

end FlareOperator.E2E.Tests.ScaleInMaster
