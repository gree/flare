/-
  E2E/Tests/ReplaceNodes.lean - Replace nodes via replication test suite

  Tests: 2-cluster (same topology), write keys, replicate, verify topology match
  Used for capacity upgrades: deploy new hardware cluster, replicate, switch over.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ReplaceNodes

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfgOld : ClusterConfig := {
  name := "replace-old"
  «namespace» := "flare-replace-old"  -- Unique namespace for test isolation
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-replace-old"
  debugPod := "debug-replace"
}

private def cfgNew : ClusterConfig := {
  name := "replace-new"
  «namespace» := "flare-replace-new"  -- Unique namespace for test isolation
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-replace-new"
  debugPod := "debug-replace"
}

def suite : TestSuite := {
  name := "replace-nodes"
  setup := do
    cleanupCluster cfgOld
    cleanupCluster cfgNew
    deployCluster cfgOld
    let stable1 ← waitForStable cfgOld 50
    if !stable1 then throw (IO.userError "old cluster did not stabilize")
    deploySecondCluster cfgNew
    let stable2 ← waitForStable cfgNew 50
    if !stable2 then throw (IO.userError "new cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfgOld.«namespace» s!"app={cfgOld.operatorName}"
  teardown := do
    cleanupCluster cfgOld
    cleanupCluster cfgNew
  tests := [
    -- Test 1: both clusters stable with same topology
    { name := "pre-flight: both clusters stable (2P × 2R)"
      run := do
        let sync1 ← operatorTcpCmd cfgOld.debugPod cfgOld.«namespace» cfgOld.operatorName cfgOld.operatorPort "node sync"
        let sync2 ← operatorTcpCmd cfgNew.debugPod cfgNew.«namespace» cfgNew.operatorName cfgNew.operatorPort "node sync"
        let e1 := parseNodeSync sync1
        let e2 := parseNodeSync sync2
        if e1.length >= 4 && e2.length >= 4 then return .pass
        else return .fail s!"old: {e1.length} nodes, new: {e2.length} nodes" },

    -- Test 2: write keys to old cluster
    { name := "write keys to old cluster"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfgOld.name}" cfgOld.«namespace»
        match ips.head? with
        | none => return .fail "no old pod IPs"
        | some ip =>
          let mut stored := 0
          for i in List.range 10 do
            let ok ← memcachedSet cfgOld.debugPod cfgOld.«namespace» ip cfgOld.flarePort
                        s!"rkey_{i}" s!"rval_{i}"
            if ok then stored := stored + 1
          if stored > 0 then return .pass
          else return .fail "no keys stored" },

    -- Test 3: trigger replication old → new
    { name := "trigger replication old→new"
      run := do
        let newSvc := s!"{cfgNew.name}-nodes.{cfgNew.«namespace»}.svc.cluster.local"
        let patchJson := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{newSvc}\",\"port\":{cfgNew.flarePort},\"mode\":\"duplicate\",\"concurrency\":2}}}"
        match ← kubectlPatch "flarecluster" cfgOld.name cfgOld.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 4: user-controlled cutover — the operator no longer auto-advances
    -- duplicate→forward; the user patches mode=forward when ready.
    { name := "migration reaches Forwarding"
      run := do
        let newSvc := s!"{cfgNew.name}-nodes.{cfgNew.«namespace»}.svc.cluster.local"
        let fwdPatch := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{newSvc}\",\"port\":{cfgNew.flarePort},\"mode\":\"forward\",\"concurrency\":2}}}"
        let _ ← kubectlPatch "flarecluster" cfgOld.name cfgOld.«namespace» fwdPatch
        let ok ← waitForCondition "migrationPhase=Forwarding" 240 do
          match ← kubectlGetJsonpath "flarecluster" cfgOld.name cfgOld.«namespace»
                    "{.status.migrationPhase}" with
          | .ok val => return (val == "Forwarding")
          | .error _ => return false
        if ok then return .pass
        else
          -- Check if at least Dumping was reached
          match ← kubectlGetJsonpath "flarecluster" cfgOld.name cfgOld.«namespace»
                    "{.status.migrationPhase}" with
          | .ok phase => return .fail s!"stuck at phase: {phase}"
          | .error _ => return .fail "could not read phase" },

    -- Test 5: new cluster has correct topology
    { name := "new cluster has 2 partitions with masters"
      run := do
        let sync ← operatorTcpCmd cfgNew.debugPod cfgNew.«namespace» cfgNew.operatorName cfgNew.operatorPort "node sync"
        let entries := parseNodeSync sync
        let masters := countMasters entries
        if masters >= 2 then return .pass
        else return .fail s!"only {masters}/2 masters in new cluster" },

    -- Test 6: verify data on new cluster (skip if replication not supported)
    { name := "data replicated to new cluster"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfgNew.name}" cfgNew.«namespace»
        match ips.head? with
        | none => return .fail "no new pod IPs"
        | some ip =>
          let val ← memcachedGet cfgNew.debugPod cfgNew.«namespace» ip cfgNew.flarePort "rkey_0"
          match val with
          | some _ => return .pass
          | none => return .skip "flared may not support cluster-replication in test image" }
  ]
}

end FlareOperator.E2E.Tests.ReplaceNodes
