/-
  E2E/Tests/WalIncrementalSync.lean - WAL incremental sync (G1)

  Verifies that after a slave pod restart within the WAL retention window,
  flared catches up via the WAL incremental sync path instead of a full dump.

  Scenario (ROCKSDB_REPLICATION.md §S1):
    1. Deploy a 2P × 2R cluster with RocksDB backend
    2. Write keys so the master has data (advances LSN)
    3. Record the slave's `rocksdb_wal_sync_success` counter
    4. Delete the slave pod (simulate slave restart)
    5. Wait for the pod to come back and re-register
    6. After reconstruction, ASSERT `rocksdb_wal_sync_success` > 0 — with a PVC
       the slave keeps its __flare_repl_last_lsn across the bounce and the master
       is unchanged, so WAL catch-up is mandatory; a full dump is a hard failure
       (this is the regression guard for the run_client-never-read-response bug).
       On a non-RocksDB image (no `rocksdb_` stats) the test skips.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.WalIncrementalSync

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "wal-sync"
  «namespace» := "flare-wal-sync"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-wal-sync"
  debugPod := "debug-wal-sync"
  storageBackend := "rocksdb"
  -- PVC: the whole point of these suites is behavior across pod restarts
  -- (prior LSN retention, purged-WAL fallback, orphan keys left on disk).
  -- On emptyDir those preconditions vanish with the pod and the interesting
  -- tests degrade to .skip; with a PVC they take their real assert paths.
  usePvc := true
}

/-- Query flared stats and return the raw output. -/
private def flaredStats (debugPod ns targetIp : String) (port : Nat) : IO String := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {targetIp} {port}"
  match ← execInDebugPod debugPod ns cmd with
  | .ok out => return out
  | .error _ => return ""

/-- Extract an integer stat field from flared stats output. -/
private def statFieldNat? (stats key : String) : Option Nat :=
  let pfx := s!"STAT {key} "
  let lines := stats.splitOn "\n" |>.map (·.trim.replace "\r" "")
  lines.findSome? fun line =>
    if line.startsWith pfx then
      (line.drop pfx.length).trim.toNat?
    else
      none

/-- Find the slave pod name for a given partition. -/
private def findSlavePod (entries : List NodeSyncEntry) (partition : Nat) : Option String :=
  match entries.find? (fun e => e.role == 1 && e.partition == Int.ofNat partition) with
  | some e => some ((e.fqdn.splitOn ".").headD e.fqdn)
  | none => none

def suite : TestSuite := {
  name := "wal-incremental-sync"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let ok ← waitForStable cfg 50
    if !ok then throw (IO.userError "cluster did not stabilize")
  -- Per-suite operators are deleted in teardown, so the CI end-of-run log
  -- dump can never capture a failing suite's logs; grab them here first.
  onFailure := dumpClusterDiagnostics cfg.«namespace»
  teardown := do
    cleanupCluster cfg
  tests := [
    -- Test 1: write data to advance master's LSN
    { name := "write keys to advance master LSN"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        match ips.head? with
        | none => return .fail "no pod IPs"
        | some ip =>
          let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "waltest" 50
          if stored >= 40 then return .pass
          else return .fail s!"only stored {stored}/50 keys" },

    -- Test 2: verify slave has rocksdb_master_id (confirming RocksDB backend)
    { name := "slave has RocksDB backend active"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findSlavePod entries 0 with
        | none => return .fail "no P0 slave found"
        | some slavePod =>
          match ← getPodIp slavePod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {slavePod}"
          | some ip =>
            let stats ← flaredStats cfg.debugPod cfg.«namespace» ip cfg.flarePort
            if containsSubstr stats "rocksdb_master_id" then return .pass
            else return .skip "flared not compiled with RocksDB" },

    -- Test 3: record baseline wal_sync_success on slave
    { name := "record baseline WAL sync counters"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findSlavePod entries 0 with
        | none => return .fail "no P0 slave found"
        | some slavePod =>
          match ← getPodIp slavePod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {slavePod}"
          | some ip =>
            let stats ← flaredStats cfg.debugPod cfg.«namespace» ip cfg.flarePort
            let syncCount := statFieldNat? stats "rocksdb_wal_sync_success" |>.getD 0
            let fallbackCount := statFieldNat? stats "rocksdb_wal_fallback_to_dump" |>.getD 0
            IO.eprintln s!"# Baseline: wal_sync_success={syncCount}, wal_fallback_to_dump={fallbackCount}"
            -- Store baseline in eprintln for later tests to reference
            -- (tests are sequential so we just re-query and compare)
            return .pass },

    -- Test 4: delete slave pod and wait for recovery
    { name := "delete slave pod and wait for re-registration"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findSlavePod entries 0 with
        | none => return .fail "no P0 slave found"
        | some slavePod =>
          IO.eprintln s!"# Deleting slave pod: {slavePod}"
          let _ ← kubectl ["delete", "pod", slavePod, "-n", cfg.«namespace»,
                            "--force", "--grace-period=0"]
          -- Wait for pod to come back and all nodes registered
          let ok ← waitForCondition "all pods ready after slave restart" 180 do
            match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                      "{.status.readyReplicas}" with
            | .ok val => return (val.toNat?.getD 0 >= cfg.partitions * cfg.replicas)
            | .error _ => return false
          if !ok then return .fail "pods did not recover after slave delete"
          -- Wait a bit for reconstruction to complete
          IO.sleep 30000
          return .pass },

    -- Test 5: verify WAL sync was used (not full dump)
    { name := "WAL sync success counter incremented after slave restart"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findSlavePod entries 0 with
        | none => return .fail "no P0 slave found after recovery"
        | some slavePod =>
          match ← getPodIp slavePod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {slavePod}"
          | some ip =>
            let stats ← flaredStats cfg.debugPod cfg.«namespace» ip cfg.flarePort
            if !containsSubstr stats "rocksdb_" then
              return .skip "flared not compiled with RocksDB"
            let syncCount := statFieldNat? stats "rocksdb_wal_sync_success" |>.getD 0
            let fallbackCount := statFieldNat? stats "rocksdb_wal_fallback_to_dump" |>.getD 0
            let midMismatch := statFieldNat? stats "rocksdb_wal_sync_master_id_mismatch" |>.getD 0
            let lsnAhead := statFieldNat? stats "rocksdb_wal_sync_lsn_ahead" |>.getD 0
            IO.eprintln s!"# After restart: wal_sync_success={syncCount}, wal_fallback_to_dump={fallbackCount}, master_id_mismatch={midMismatch}, lsn_ahead={lsnAhead}"
            -- This suite runs on a PVC (usePvc := true): the force-deleted slave
            -- is recreated with the SAME PVC, so its RocksDB — including
            -- __flare_repl_last_lsn and master_id — survives the bounce. Only
            -- the slave was deleted, so the P0 master (and its lineage) is
            -- unchanged. Therefore the slave MUST catch up via WAL incremental
            -- sync; a full dump here is a real defect, not an acceptable skip.
            --
            -- (Do NOT re-add a `fallback_to_dump > 0 -> skip` branch: it silently
            -- masked the regression where op_repl_sync_wal::run_client never read
            -- the streamed response, so _client_result stayed at its default and
            -- EVERY reconstruction fell back to a full dump with wal_sync_success
            -- stuck at 0. This test's whole job is to fail on exactly that.)
            if syncCount > 0 then return .pass
            else
              return .fail s!"WAL incremental sync never succeeded on a PVC slave restart (wal_sync_success=0, fallback_to_dump={fallbackCount}, master_id_mismatch={midMismatch}, lsn_ahead={lsnAhead}) — the slave kept its LSN on the PVC and the master was unchanged, so it must catch up via WAL, not a full dump" }
  ]
}

end FlareOperator.E2E.Tests.WalIncrementalSync
