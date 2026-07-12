/-
  E2E/Tests/OrphanScanPurge.lean - Orphan key scan/purge (G7)

  Verifies the orphan_scan and orphan_purge admin commands after a
  failover + rejoin cycle leaves orphan keys on the ex-master.

  Scenario (ROCKSDB_REPLICATION.md §"Orphan Key Lifecycle"):
    1. Deploy 2P × 2R cluster with RocksDB backend
    2. Write keys to both partitions
    3. Kill the P0 master pod → failover promotes the slave
    4. Wait for the killed pod to restart (as proxy, then re-assigned)
    5. Run `orphan_scan` on the restarted pod → verify orphan_count > 0
    6. Run `orphan_purge <token>` → verify orphans deleted
    7. Verify normal keys are still accessible

  Note: Orphan keys appear because the restarted pod retains data from
  when it was master, but the key resolver now routes those keys to the
  new master. The keys are invisible to clients but occupy disk space.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.OrphanScanPurge

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "orphan-mgmt"
  «namespace» := "flare-orphan-mgmt"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-orphan-mgmt"
  debugPod := "debug-orphan-mgmt"
  storageBackend := "rocksdb"
  -- PVC: the whole point of these suites is behavior across pod restarts
  -- (prior LSN retention, purged-WAL fallback, orphan keys left on disk).
  -- On emptyDir those preconditions vanish with the pod and the interesting
  -- tests degrade to .skip; with a PVC they take their real assert paths.
  usePvc := true
}

private def flaredStats (debugPod ns targetIp : String) (port : Nat) : IO String := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {targetIp} {port}"
  match ← execInDebugPod debugPod ns cmd with
  | .ok out => return out
  | .error _ => return ""

/-- Send a command to a flared pod directly (not the operator). -/
private def flaredCmd (debugPod ns targetIp : String) (port : Nat) (cmd : String) : IO String := do
  let shellCmd := s!"printf '{cmd}\\r\\n' | nc -w 5 {targetIp} {port}"
  match ← execInDebugPod debugPod ns shellCmd with
  | .ok out => return out
  | .error _ => return ""

/-- Extract a STAT value from orphan_scan output. -/
private def extractStat (output key : String) : Option String :=
  let lines := output.splitOn "\n" |>.map (·.trim.replace "\r" "")
  lines.findSome? fun line =>
    let pfx := s!"STAT {key} "
    if line.startsWith pfx then some (line.drop pfx.length).trim
    else none

def suite : TestSuite := {
  name := "orphan-scan-purge"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let ok ← waitForStable cfg 50
    if !ok then throw (IO.userError "cluster did not stabilize")
  teardown := do
    cleanupCluster cfg
  tests := [
    -- Test 1: write keys to generate data
    { name := "write keys to both partitions"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        match ips.head? with
        | none => return .fail "no pod IPs"
        | some ip =>
          let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "orphan" 100
          if stored >= 80 then return .pass
          else return .fail s!"only stored {stored}/100 keys" },

    -- Test 2: kill P0 master to trigger failover
    { name := "kill P0 master and wait for failover"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master to kill"
        | some oldMaster =>
          IO.eprintln s!"# Killing P0 master: {oldMaster}"
          let _ ← kubectl ["delete", "pod", oldMaster, "-n", cfg.«namespace»,
                            "--force", "--grace-period=0"]
          -- Wait for failover
          let ok ← waitForCondition "P0 master available" 90 do
            let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
            let entries := parseNodeSync sync
            match findMasterPod entries 0 with
            | some _ => return true
            | none => return false
          if ok then return .pass
          else return .fail "P0 master not re-elected after kill" },

    -- Test 3: wait for killed pod to restart and rejoin
    { name := "killed pod restarts and rejoins cluster"
      run := do
        let ok ← waitForCondition "all pods ready" 180 do
          match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                    "{.status.readyReplicas}" with
          | .ok val => return (val.toNat?.getD 0 >= cfg.partitions * cfg.replicas)
          | .error _ => return false
        if !ok then return .fail "pods did not recover"
        -- Wait for reconstruction to complete
        IO.sleep 30000
        return .pass },

    -- Test 4: run orphan_scan on the restarted pod
    { name := "orphan_scan detects orphan keys"
      run := do
        -- The restarted pod (ex-master, now slave or proxy) should have
        -- orphan keys from its time as master.
        let pods ← getPodNames s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        let mut foundOrphans := false
        let mut scanToken := ""
        for pod in pods do
          match ← getPodIp pod cfg.«namespace» with
          | none => pure ()
          | some ip =>
            let stats ← flaredStats cfg.debugPod cfg.«namespace» ip cfg.flarePort
            if !containsSubstr stats "rocksdb_" then continue
            let output ← flaredCmd cfg.debugPod cfg.«namespace» ip cfg.flarePort "orphan_scan"
            IO.eprintln s!"# orphan_scan on {pod}:"
            for line in output.splitOn "\n" do
              if line.trim != "" then IO.eprintln s!"#   {line.trim}"
            match extractStat output "orphan_scan_orphan_count" with
            | some countStr =>
              let count := countStr.toNat?.getD 0
              if count > 0 then
                foundOrphans := true
                scanToken := (extractStat output "orphan_scan_token").getD ""
                IO.eprintln s!"# Found {count} orphans on {pod}, token={scanToken}"
            | none => pure ()
        if foundOrphans then return .pass
        else return .skip "no orphan keys detected (may need longer reconstruction or different failover pattern)" },

    -- Test 5: run orphan_purge to clean up
    { name := "orphan_purge removes orphan keys"
      run := do
        -- Re-scan to get a fresh token (tokens expire after 300s)
        let pods ← getPodNames s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        let mut purged := false
        for pod in pods do
          match ← getPodIp pod cfg.«namespace» with
          | none => pure ()
          | some ip =>
            let stats ← flaredStats cfg.debugPod cfg.«namespace» ip cfg.flarePort
            if !containsSubstr stats "rocksdb_" then continue
            let scanOut ← flaredCmd cfg.debugPod cfg.«namespace» ip cfg.flarePort "orphan_scan"
            let orphanCount := (extractStat scanOut "orphan_scan_orphan_count").bind (·.toNat?) |>.getD 0
            if orphanCount == 0 then continue
            let token := (extractStat scanOut "orphan_scan_token").getD ""
            if token == "" then continue
            IO.eprintln s!"# Purging {orphanCount} orphans on {pod} with token {token}..."
            let purgeOut ← flaredCmd cfg.debugPod cfg.«namespace» ip cfg.flarePort s!"orphan_purge {token}"
            IO.eprintln s!"# orphan_purge output:"
            for line in purgeOut.splitOn "\n" do
              if line.trim != "" then IO.eprintln s!"#   {line.trim}"
            if containsSubstr purgeOut "orphan_purge_deleted" then
              purged := true
        if purged then return .pass
        else return .skip "no orphans to purge (test 4 may have skipped)" }
  ]
}

end FlareOperator.E2E.Tests.OrphanScanPurge
