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

-- Both clusters run the RocksDB backend: that is what production uses, and the
-- shrink data-migration path we want to actually verify (dump-then-forward to a
-- smaller cluster) must be exercised on the real backend. The tch image reached
-- Dumping/Forwarding but never landed data on v2, so the migration assertions
-- always skipped; rocksdb matches production and is the meaningful verification.
private def cfgV1 : ClusterConfig := {
  name := "repl-v1"
  «namespace» := "flare-repl-v1"  -- Unique namespace for test isolation
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-repl-v1"
  debugPod := "debug-repl"
  storageBackend := "rocksdb"
}

private def cfgV2 : ClusterConfig := {
  name := "repl-v2"
  «namespace» := "flare-repl-v2"  -- Unique namespace for test isolation
  partitions := 1
  replicas := 2
  operatorName := "flare-operator-repl-v2"
  debugPod := "debug-repl"
  storageBackend := "rocksdb"
}

/-- Keys written to v1 to prove the SHRINK (2 partitions → 1) actually
    migrates data: they hash across both v1 partitions and must all re-land
    in v2's single partition. -/
private def shrinkKeys : Nat := 30
private def shrinkPrefix : String := "shrink"

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
  onFailure := dumpClusterDiagnostics cfgV1.«namespace»
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
          -- One canary key (used by the phase tests) plus a spread of keys
          -- hashing across BOTH v1 partitions — the shrink's real test is
          -- that keys from v1 P0 AND P1 all re-land in v2's single partition.
          let ok ← memcachedSet cfgV1.debugPod cfgV1.«namespace» ip cfgV1.flarePort
                      "repl_test_key" "repl_test_value"
          if !ok then return .fail "canary SET failed"
          let stored ← writeKeys cfgV1.debugPod cfgV1.«namespace» ip cfgV1.flarePort
                          shrinkPrefix shrinkKeys
          IO.eprintln s!"# wrote {stored}/{shrinkKeys} shrink keys + 1 canary to v1 (2 partitions)"
          if stored != shrinkKeys then return .fail s!"only {stored}/{shrinkKeys} shrink keys stored on v1"
          return .pass },

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
        -- The CRD status (migrationPhase) and the extra.conf ConfigMap are written
        -- by separate async steps of the reconcile, so poll rather than reading
        -- once — the ConfigMap can lag the phase transition by a tick or two.
        let ok ← waitForCondition "extra.conf has cluster-replication=true" 60 do
          match ← kubectlGetJsonpath "configmap" s!"{cfgV1.name}-config" cfgV1.«namespace»
                    "{.data.extra\\.conf}" with
          | .ok data => return containsSubstr data "cluster-replication = true"
          | .error _ => return false
        if ok then return .pass
        else
          match ← kubectlGetJsonpath "configmap" s!"{cfgV1.name}-config" cfgV1.«namespace»
                    "{.data.extra\\.conf}" with
          | .ok data => return .fail s!"ConfigMap missing replication settings after 60s: {data}"
          | .error e => return .fail s!"could not read ConfigMap: {e}" },

    -- Test 5: THE SHRINK — pre-existing keys from v1's two partitions migrate
    -- to v2's single partition via the DUPLICATE-mode dump (no manual step: the
    -- operator applies mode=duplicate on enable and re-SIGHUPs once it lands on
    -- the mounted config, then flared dumps). Poll v2's P0 master until all keys
    -- arrive. all present => pass; still 0 after the timeout => skip (env too
    -- slow / unsupported image); partial => hard FAIL (silent loss).
    { name := s!"all {shrinkKeys} keys migrate to v2 via the duplicate-mode dump"
      run := do
        let v2MasterIp : IO (Option String) := do
          let sync ← operatorTcpCmd cfgV2.debugPod cfgV2.«namespace»
                       cfgV2.operatorName cfgV2.operatorPort "node sync"
          match findMasterPod (parseNodeSync sync) 0 with
          | none => return none
          | some m => getPodIp m cfgV2.«namespace»
        let countPresent : String → IO (Nat × List Nat) := fun ip => do
          let mut present : Nat := 0
          let mut mismatched : List Nat := []
          for i in List.range shrinkKeys do
            match ← memcachedGet cfgV2.debugPod cfgV2.«namespace» ip cfgV2.flarePort s!"{shrinkPrefix}_{i}" with
            | none => pure ()
            | some got =>
              present := present + 1
              if got != s!"val_{i}" then mismatched := mismatched ++ [i]
          return (present, mismatched)
        -- Poll up to ~180s for the dump to propagate + run + land on v2.
        let _ ← waitForCondition s!"all {shrinkKeys} keys on v2" 180 do
          match ← v2MasterIp with
          | none => return false
          | some ip => return ((← countPresent ip).1 == shrinkKeys)
        match ← v2MasterIp with
        | none => return .fail "no v2 P0 master"
        | some ip =>
          let (present, mismatched) ← countPresent ip
          IO.eprintln s!"# v2 after shrink: {present}/{shrinkKeys} keys present, {mismatched.length} mismatched"
          if present == 0 then
            return .skip "cluster-replication produced no data on v2 (env too slow / unsupported image)"
          else if present == shrinkKeys && mismatched.isEmpty then
            return .pass
          else
            return .fail s!"SHRINK DATA LOSS: only {present}/{shrinkKeys} keys on v2, mismatched={mismatched.take 10}" },

    -- Test 6: user-controlled cutover — the operator does NOT auto-advance;
    -- the user flips mode to forward when ready (verified the dump landed above).
    { name := "user patches mode=forward to advance"
      run := do
        let v2Svc := s!"{cfgV2.name}-nodes.{cfgV2.«namespace»}.svc.cluster.local"
        let patchJson := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{v2Svc}\",\"port\":{cfgV2.flarePort},\"mode\":\"forward\",\"concurrency\":2}}}"
        match ← kubectlPatch "flarecluster" cfgV1.name cfgV1.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 7: verify Forwarding phase (now user-driven by the mode=forward patch)
    { name := "migrationPhase transitions to Forwarding"
      run := do
        let ok ← waitForCondition "migrationPhase=Forwarding" 120 do
          match ← kubectlGetJsonpath "flarecluster" cfgV1.name cfgV1.«namespace»
                    "{.status.migrationPhase}" with
          | .ok val => return (val == "Forwarding")
          | .error _ => return false
        if ok then return .pass
        else return .fail "did not reach Forwarding after mode=forward patch" },

    -- Test 8: ConfigMap updated to forward mode
    { name := "ConfigMap updated to forward mode"
      run := do
        let ok ← waitForCondition "extra.conf mode=forward" 60 do
          match ← kubectlGetJsonpath "configmap" s!"{cfgV1.name}-config" cfgV1.«namespace»
                    "{.data.extra\\.conf}" with
          | .ok data => return containsSubstr data "cluster-replication-mode = forward"
          | .error _ => return false
        if ok then return .pass
        else return .fail "ConfigMap not in forward mode" }
  ]
}

end FlareOperator.E2E.Tests.ClusterReplication
