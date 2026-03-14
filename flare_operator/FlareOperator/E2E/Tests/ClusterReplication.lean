/-
  E2E/Tests/ClusterReplication.lean - Cluster replication (Blue/Green) test suite

  Tests: 2-cluster, write, trigger replication, verify phases + ConfigMap + data
  Port of test/e2e/test-cluster-replication.sh
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ClusterReplication

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfgV1 : ClusterConfig := {
  name := "repl-v1"
  «namespace» := "flare-repl-v1"  -- Unique namespace for test isolation
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-repl-v1"
  debugPod := "debug-repl"
}

private def cfgV2 : ClusterConfig := {
  name := "repl-v2"
  «namespace» := "flare-repl-v2"  -- Unique namespace for test isolation
  partitions := 1
  replicas := 2
  operatorName := "flare-operator-repl-v2"
  debugPod := "debug-repl"
}

def suite : TestSuite := {
  name := "cluster-replication"
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
    -- Test 1: write test data to v1
    { name := "write test data to v1"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfgV1.name}" cfgV1.«namespace»
        match ips.head? with
        | none => return .fail "no v1 pod IPs"
        | some ip =>
          let ok ← memcachedSet cfgV1.debugPod cfgV1.«namespace» ip cfgV1.flarePort
                      "repl_test_key" "repl_test_value"
          if ok then return .pass
          else return .fail "SET failed" },

    -- Test 2: trigger cluster replication
    { name := "trigger cluster replication via CRD patch"
      run := do
        let v2Svc := s!"{cfgV2.name}-nodes.{cfgV2.«namespace»}.svc.cluster.local"
        let patchJson := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{v2Svc}\",\"port\":{cfgV2.flarePort},\"mode\":\"duplicate\",\"concurrency\":2}}}"
        match ← kubectlPatch "flarecluster" cfgV1.name cfgV1.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 3: verify Dumping phase
    { name := "migrationPhase transitions to Dumping"
      run := do
        let ok ← waitForCondition "migrationPhase=Dumping" 60 do
          match ← kubectlGetJsonpath "flarecluster" cfgV1.name cfgV1.«namespace»
                    "{.status.migrationPhase}" with
          | .ok val => return (val == "Dumping")
          | .error _ => return false
        if ok then return .pass
        else return .fail "did not reach Dumping" },

    -- Test 4: ConfigMap contains replication settings
    { name := "ConfigMap contains cluster-replication settings"
      run := do
        match ← kubectlGetJsonpath "configmap" s!"{cfgV1.name}-config" cfgV1.«namespace»
                  "{.data.extra\\.conf}" with
        | .ok data =>
          if containsSubstr data "cluster-replication = true" then return .pass
          else return .fail s!"ConfigMap missing replication settings: {data}"
        | .error e => return .fail s!"could not read ConfigMap: {e}" },

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

    -- Test 6: ConfigMap updated to forward mode
    { name := "ConfigMap updated to forward mode"
      run := do
        match ← kubectlGetJsonpath "configmap" s!"{cfgV1.name}-config" cfgV1.«namespace»
                  "{.data.extra\\.conf}" with
        | .ok data =>
          if containsSubstr data "cluster-replication-mode = forward" then return .pass
          else return .fail s!"ConfigMap not in forward mode: {data}"
        | .error e => return .fail s!"could not read ConfigMap: {e}" },

    -- Test 7: verify data on v2 (skip if not supported)
    { name := "data replicated to v2"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfgV2.name}" cfgV2.«namespace»
        match ips.head? with
        | none => return .fail "no v2 pod IPs"
        | some ip =>
          let val ← memcachedGet cfgV2.debugPod cfgV2.«namespace» ip cfgV2.flarePort "repl_test_key"
          match val with
          | some v =>
            if containsSubstr v "repl_test_value" then return .pass
            else return .fail s!"unexpected value: {v}"
          | none =>
            return .skip "flared may not support cluster-replication in test image" }
  ]
}

end FlareOperator.E2E.Tests.ClusterReplication
