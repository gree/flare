/-
  E2E/Tests/FailoverDuringReplication.lean - Failover during cluster-replication

  Verifies that a master failover during an active blue/green migration
  does not break the replication state machine (Vitess #8909 equivalent).

  Scenario:
    1. Deploy v1 cluster (2P × 2R) and v2 cluster (1P × 2R)
    2. Trigger cluster replication v1→v2
    3. Wait for Dumping phase
    4. Kill the v1 P0 master DURING Dumping
    5. Verify v1 cluster failover succeeds (new P0 master elected)
    6. Verify replication eventually reaches Forwarding (or stays in
       Dumping with recovery — both are acceptable)
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.Kubectl

namespace FlareOperator.E2E.Tests.FailoverDuringReplication

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfgV1 : ClusterConfig := {
  name := "fdr-v1"
  «namespace» := "flare-fdr-v1"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-fdr-v1"
  debugPod := "debug-fdr"
}

private def cfgV2 : ClusterConfig := {
  name := "fdr-v2"
  «namespace» := "flare-fdr-v2"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator-fdr-v2"
  debugPod := "debug-fdr"
}

def suite : TestSuite := {
  name := "failover-during-replication"
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
    -- Test 1: write data to v1
    { name := "write test data to v1"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfgV1.name}" cfgV1.«namespace»
        match ips.head? with
        | none => return .fail "no v1 pod IPs"
        | some ip =>
          let stored ← writeKeys cfgV1.debugPod cfgV1.«namespace» ip cfgV1.flarePort "fdr" 50
          if stored >= 40 then return .pass
          else return .fail s!"only stored {stored}/50" },

    -- Test 2: trigger replication
    { name := "trigger cluster replication v1→v2"
      run := do
        let v2Svc := s!"{cfgV2.name}-nodes.{cfgV2.«namespace»}.svc.cluster.local"
        let patchJson := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{v2Svc}\",\"port\":{cfgV2.flarePort},\"mode\":\"duplicate\",\"concurrency\":2}}}"
        match ← kubectlPatch "flarecluster" cfgV1.name cfgV1.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 3: wait for Dumping phase
    { name := "migrationPhase transitions to Dumping"
      run := do
        let ok ← waitForCondition "migrationPhase=Dumping" 60 do
          match ← kubectlGetJsonpath "flarecluster" cfgV1.name cfgV1.«namespace»
                    "{.status.migrationPhase}" with
          | .ok val => return (val == "Dumping")
          | .error _ => return false
        if ok then return .pass
        else return .fail "did not reach Dumping" },

    -- Test 4: kill v1 P0 master DURING Dumping
    { name := "kill v1 P0 master during Dumping phase"
      run := do
        let sync ← operatorTcpCmd cfgV1.debugPod cfgV1.«namespace» cfgV1.operatorName cfgV1.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master to kill"
        | some oldMaster =>
          IO.eprintln s!"# Killing v1 P0 master {oldMaster} during Dumping..."
          let _ ← kubectl ["delete", "pod", oldMaster, "-n", cfgV1.«namespace»,
                            "--force", "--grace-period=0"]
          return .pass },

    -- Test 5: verify failover on v1
    { name := "v1 failover: new P0 master elected"
      run := do
        let ok ← waitForCondition "P0 master available" 90 do
          let sync ← operatorTcpCmd cfgV1.debugPod cfgV1.«namespace» cfgV1.operatorName cfgV1.operatorPort "node sync"
          let entries := parseNodeSync sync
          match findMasterPod entries 0 with
          | some _ => return true
          | none => return false
        if ok then return .pass
        else return .fail "P0 master not re-elected after kill during Dumping" },

    -- Test 6: verify replication state is not broken
    -- After failover, the migration should either:
    --   a) Continue Dumping and eventually reach Forwarding, OR
    --   b) Stay in Dumping (new master restarts dump_replication)
    -- Either is acceptable. What would be a bug: stuck in None, or an error.
    { name := "replication state recoverable after failover"
      run := do
        -- Give the operator a few cycles to recover
        IO.sleep 15000
        match ← kubectlGetJsonpath "flarecluster" cfgV1.name cfgV1.«namespace»
                  "{.status.migrationPhase}" with
        | .ok phase =>
          if phase == "Dumping" || phase == "Forwarding" then
            IO.eprintln s!"# Replication phase after failover: {phase} (OK)"
            return .pass
          else
            return .fail s!"replication phase is '{phase}' after failover (expected Dumping or Forwarding)"
        | .error e => return .fail s!"could not read migrationPhase: {e}" }
  ]
}

end FlareOperator.E2E.Tests.FailoverDuringReplication
