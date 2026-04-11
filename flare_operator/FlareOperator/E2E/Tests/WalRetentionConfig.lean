/-
  E2E/Tests/WalRetentionConfig.lean - RocksDB WAL retention config propagation

  Verifies that the operator propagates `spec.rocksdb.*` fields from the
  FlareCluster CR into the flared ConfigMap (`{crName}-config`, key `extra.conf`)
  and that flared reflects the new values in its stats.

  Scenarios covered (G10 from docs/e2e-test-issues.md):
    1. Patching `spec.rocksdb.walTtlSeconds` on a running cluster causes the
       operator to re-render extra.conf with `rocksdb-wal-ttl-seconds = <n>`.
    2. Patching `spec.rocksdb.walSizeLimitMb` is similarly propagated as
       `rocksdb-wal-size-limit-mb = <n>`.
    3. Updating both fields to new values triggers a second re-render.
    4. (Best-effort) Flared stats expose `rocksdb_wal_ttl_seconds` matching
       the configured value — skipped if the test image does not compile in
       RocksDB support.

  Non-goals:
    - Actually exercising WAL incremental sync (covered by G1).
    - Validating `rocksdb_sync_writes` or bandwidth limits (covered by G11, G12).
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.WalRetentionConfig

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfg : ClusterConfig := {
  name := "wal-retention"
  «namespace» := "flare-wal-retention"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-wal-retention"
  debugPod := "debug-wal-retention"
}

/-- Poll the ConfigMap's `extra.conf` until it contains the given substring,
    or until timeout. Returns the final ConfigMap content (or empty on error). -/
private def waitForConfigLine (crName ns : String) (needle : String)
    (timeoutSec : Nat) : IO (Bool × String) := do
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

/-- Query flared stats via the debug pod and return the raw stats output. -/
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
  name := "wal-retention-config"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let ok ← waitForStable cfg 50
    if !ok then throw (IO.userError "cluster did not stabilize")
  teardown := do
    cleanupCluster cfg
  tests := [
    -- Test 1: baseline — ConfigMap exists (even if empty of rocksdb settings)
    { name := "pre-flight: ConfigMap exists with extra.conf key"
      run := do
        match ← kubectlGetJsonpath "configmap" s!"{cfg.name}-config" cfg.«namespace»
                  "{.data.extra\\.conf}" with
        | .ok _ => return .pass
        | .error e => return .fail s!"ConfigMap missing or unreadable: {e}" },

    -- Test 2: patch walTtlSeconds → operator should render it into extra.conf
    { name := "patch spec.rocksdb.walTtlSeconds is propagated to ConfigMap"
      run := do
        let patch := "{\"spec\":{\"rocksdb\":{\"walTtlSeconds\":1800}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          let (found, content) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-wal-ttl-seconds = 1800" 60
          if found then return .pass
          else return .fail s!"ConfigMap did not contain rocksdb-wal-ttl-seconds = 1800; actual: {content}" },

    -- Test 3: patch walSizeLimitMb alongside existing walTtlSeconds
    { name := "patch spec.rocksdb.walSizeLimitMb is propagated to ConfigMap"
      run := do
        let patch := "{\"spec\":{\"rocksdb\":{\"walTtlSeconds\":1800,\"walSizeLimitMb\":2048}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          let (found, content) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-wal-size-limit-mb = 2048" 60
          if !found then
            return .fail s!"ConfigMap missing walSizeLimitMb; actual: {content}"
          -- walTtlSeconds must still be present after the second patch
          if !containsSubstr content "rocksdb-wal-ttl-seconds = 1800" then
            return .fail s!"walTtlSeconds was clobbered by second patch; actual: {content}"
          return .pass },

    -- Test 4: updating walTtlSeconds to a new value re-renders the ConfigMap
    { name := "updating walTtlSeconds triggers re-render"
      run := do
        let patch := "{\"spec\":{\"rocksdb\":{\"walTtlSeconds\":600,\"walSizeLimitMb\":2048}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          let (found, content) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-wal-ttl-seconds = 600" 60
          if !found then
            return .fail s!"ConfigMap did not reflect updated walTtlSeconds; actual: {content}"
          -- Ensure the old value is gone (not duplicated)
          if containsSubstr content "rocksdb-wal-ttl-seconds = 1800" then
            return .fail s!"Stale walTtlSeconds=1800 still present in extra.conf; actual: {content}"
          return .pass },

    -- Test 5: flared stats reflect the configured WAL TTL (best-effort)
    --
    -- This requires:
    --   (a) the flared binary to be compiled with RocksDB support,
    --   (b) the operator to have sent SIGHUP so flared re-read extra.conf.
    --
    -- If the test image does not compile in RocksDB, flared's `stats` output
    -- will not include any `rocksdb_*` fields — in that case we SKIP rather
    -- than fail, so this suite remains useful even on non-RocksDB images.
    { name := "flared stats expose rocksdb_wal_ttl_seconds"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        match ips.head? with
        | none => return .fail "no flared pod IPs"
        | some ip =>
          let stats ← flaredStats cfg.debugPod cfg.«namespace» ip cfg.flarePort
          if !containsSubstr stats "rocksdb_" then
            return .skip "flared image does not expose rocksdb_* stats (not compiled with RocksDB)"
          match statFieldNat? stats "rocksdb_wal_ttl_seconds" with
          | none =>
            return .fail s!"stats exposed rocksdb_* but not rocksdb_wal_ttl_seconds; stats:\n{stats}"
          | some n =>
            if n == 600 then return .pass
            else return .fail s!"flared reports rocksdb_wal_ttl_seconds={n}, expected 600" }
  ]
}

end FlareOperator.E2E.Tests.WalRetentionConfig
