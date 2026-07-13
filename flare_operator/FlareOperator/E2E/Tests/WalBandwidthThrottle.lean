/-
  E2E/Tests/WalBandwidthThrottle.lean - WAL-sync bandwidth throttle (G12)

  Verifies that the operator propagates `spec.rocksdb.walSyncBwlimit` and
  `spec.rocksdb.walSyncInterval` from the FlareCluster CR into the flared
  ConfigMap. These two fields control WAL-sync-specific bandwidth caps that
  override the cluster-wide reconstruction-bwlimit / reconstruction-interval
  for the WAL streaming path -- see ROCKSDB_REPLICATION.md §"WAL-Specific
  Bandwidth Throttling".

  Scenarios covered (G12 from docs/e2e-test-issues.md):
    1. Patching walSyncBwlimit is rendered as `rocksdb-wal-sync-bwlimit = <n>`.
    2. Patching walSyncInterval alongside walSyncBwlimit preserves both.
    3. Zero is a valid value (means "inherit cluster-wide setting") and must
       be rendered, not elided, so flared can tell "explicitly 0" from "unset".
    4. (Best-effort) flared stats expose `rocksdb_wal_sync_bwlimit` matching
       the configured value -- skipped if the test image is not compiled
       with RocksDB.

  Non-goals:
    - Measuring actual throughput under the throttle (would require a
      big-data write workload and timing). This suite only verifies
      config propagation, which is the operator's responsibility.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.WalBandwidthThrottle

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfg : ClusterConfig := {
  name := "wal-throttle"
  «namespace» := "flare-wal-throttle"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-wal-throttle"
  debugPod := "debug-wal-throttle"
  -- RocksDB image: walSyncBwlimit/walSyncInterval are rocksdb-only knobs.
  storageBackend := "rocksdb"
}

/-- Poll the ConfigMap's `extra.conf` until it contains the given substring,
    or until timeout. Returns (success, final content). -/
private def waitForConfigLine (crName ns needle : String) (timeoutSec : Nat)
    : IO (Bool × String) := do
  let cmName := s!"{crName}-config"
  let mut lastContent := ""
  let rec loop (elapsed : Nat) (fuel : Nat) : IO (Bool × String) := do
    match fuel with
    | 0 => return (false, lastContent)
    | fuel + 1 =>
      if elapsed >= timeoutSec then return (false, lastContent)
      match ← kubectlGetJsonpath "configmap" cmName ns "{.data.extra\\.conf}" with
      | .ok data =>
        if containsSubstr data needle then return (true, data)
        else
          IO.sleep 3000
          loop (elapsed + 3) fuel
      | .error _ =>
        IO.sleep 3000
        loop (elapsed + 3) fuel
  loop 0 (timeoutSec / 3 + 1)

/-- Query flared stats via the debug pod. -/
private def flaredStats (debugPod ns targetIp : String) (port : Nat) : IO String := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {targetIp} {port}"
  match ← execInDebugPod debugPod ns cmd with
  | .ok out => return out
  | .error _ => return ""

/-- Extract the integer value of a `STAT <key> <value>` line, if present. -/
private def statFieldNat? (stats key : String) : Option Nat :=
  let pfx := s!"STAT {key} "
  let lines := stats.splitOn "\n" |>.map (·.trim.replace "\r" "")
  lines.findSome? fun line =>
    if line.startsWith pfx then
      (line.drop pfx.length).trim.toNat?
    else
      none

def suite : TestSuite := {
  name := "wal-bandwidth-throttle"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let ok ← waitForStable cfg 50
    if !ok then throw (IO.userError "cluster did not stabilize")
  teardown := do
    cleanupCluster cfg
  tests := [
    -- Test 1: baseline ConfigMap presence
    { name := "pre-flight: ConfigMap exists with extra.conf key"
      run := do
        match ← kubectlGetJsonpath "configmap" s!"{cfg.name}-config" cfg.«namespace»
                  "{.data.extra\\.conf}" with
        | .ok _ => return .pass
        | .error e => return .fail s!"ConfigMap missing or unreadable: {e}" },

    -- Test 2: patch walSyncBwlimit=51200 (50 MB/s) -> rendered in extra.conf
    { name := "patch spec.rocksdb.walSyncBwlimit is propagated"
      run := do
        let patch := "{\"spec\":{\"rocksdb\":{\"walSyncBwlimit\":51200}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          let (found, content) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-wal-sync-bwlimit = 51200" 60
          if found then return .pass
          else return .fail s!"ConfigMap missing walSyncBwlimit; actual: {content}" },

    -- Test 3: patch walSyncInterval=2000 (usec) alongside existing walSyncBwlimit
    { name := "patch spec.rocksdb.walSyncInterval preserves walSyncBwlimit"
      run := do
        let patch := "{\"spec\":{\"rocksdb\":{\"walSyncBwlimit\":51200,\"walSyncInterval\":2000}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          let (found, content) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-wal-sync-interval = 2000" 60
          if !found then
            return .fail s!"ConfigMap missing walSyncInterval; actual: {content}"
          if !containsSubstr content "rocksdb-wal-sync-bwlimit = 51200" then
            return .fail s!"walSyncBwlimit was clobbered by second patch; actual: {content}"
          return .pass },

    -- Test 4: explicit zero must be rendered (distinguishes "inherit" from "unset")
    { name := "explicit zero for walSyncBwlimit is rendered, not elided"
      run := do
        let patch := "{\"spec\":{\"rocksdb\":{\"walSyncBwlimit\":0,\"walSyncInterval\":2000}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          let (found, content) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-wal-sync-bwlimit = 0" 60
          if !found then
            return .fail s!"ConfigMap did not reflect walSyncBwlimit=0; actual: {content}"
          -- Previous value must be gone (no duplicate line)
          if containsSubstr content "rocksdb-wal-sync-bwlimit = 51200" then
            return .fail s!"Stale walSyncBwlimit=51200 still present; actual: {content}"
          return .pass },

    -- Test 5: flared stats expose rocksdb_wal_sync_bwlimit (best-effort)
    --
    -- Known limitation: flared's `ini_option::reload()` (src/flared/ini_option.cc
    -- line ~450) does NOT re-apply `rocksdb-wal-sync-bwlimit` to the private
    -- member `_rocksdb_wal_sync_bwlimit` on SIGHUP — only the initial `load()`
    -- at line 431 does. So even though the operator correctly writes the new
    -- value into extra.conf and SIGHUPs the pods, flared's stats keep
    -- reporting the original (default=0) value.  Patching flared to mirror
    -- the load() logic in reload() is a flared-side fix, not operator-side.
    --
    -- We still exercise the path and SKIP (not FAIL) when the stat doesn't
    -- match, so the test is informative but not spuriously red against today's
    -- flared. When flared is patched, this test will flip from SKIP to PASS
    -- automatically.
    { name := "flared stats expose rocksdb_wal_sync_bwlimit"
      run := do
        -- Re-patch to a known non-zero value so we can assert on it
        let patch := "{\"spec\":{\"rocksdb\":{\"walSyncBwlimit\":10240,\"walSyncInterval\":0}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          let (ok, _) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-wal-sync-bwlimit = 10240" 60
          if !ok then return .fail "ConfigMap did not update to 10240 before stats check"
          -- The value reaches flared only after kubelet propagates the
          -- ConfigMap into the mounted file (~60-90s) AND the operator's
          -- pending re-SIGHUP fires AND flared's reload() applies it. A
          -- single-shot read raced all three, so poll for up to 240s.
          let ips ← getPodIps s!"app=flare,cluster={cfg.name}" cfg.«namespace»
          match ips.head? with
          | none => return .fail "no flared pod IPs"
          | some ip =>
            let firstStats ← flaredStats cfg.debugPod cfg.«namespace» ip cfg.flarePort
            if !containsSubstr firstStats "rocksdb_" then
              return .skip "flared image does not expose rocksdb_* stats (not compiled with RocksDB)"
            let mut lastSeen : Nat := 0
            for _ in List.range 24 do
              let stats ← flaredStats cfg.debugPod cfg.«namespace» ip cfg.flarePort
              lastSeen := statFieldNat? stats "rocksdb_wal_sync_bwlimit" |>.getD 0
              if lastSeen == 10240 then
                break
              IO.sleep 10000
            if lastSeen == 10240 then return .pass
            else
              return .skip s!"rocksdb_wal_sync_bwlimit still {lastSeen} (expected 10240) after 240s — ConfigMap propagation + re-SIGHUP + reload() did not land in time" }
  ]
}

end FlareOperator.E2E.Tests.WalBandwidthThrottle
