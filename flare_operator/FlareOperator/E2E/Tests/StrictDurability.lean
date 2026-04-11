/-
  E2E/Tests/StrictDurability.lean - rocksdb-sync-writes propagation (G11)

  Verifies that the operator propagates `spec.rocksdb.syncWrites` from the
  FlareCluster CR into the flared ConfigMap. This is the boolean counterpart
  to wal-retention-config (G10): it exercises the `Option Bool` field path
  through the CRD parser, the renderer, and the reconcile idempotency check.

  Scenarios covered (G11 from docs/e2e-test-issues.md):
    1. Patching `spec.rocksdb.syncWrites=true` is rendered as
       `rocksdb-sync-writes = true` in extra.conf.
    2. Patching back to `false` cleanly replaces the value (no stale "true"
       remains, no duplicate lines).
    3. Setting `syncWrites` alongside `walTtlSeconds` preserves both fields
       (cross-field preservation test for the boolean path).
    4. (Best-effort) flared stats expose `rocksdb_sync_writes` — skipped if
       the test image is not compiled with RocksDB.

  Non-goals:
    - Actually measuring durability / fsync behavior (would require a
      kill-9 test). This suite only verifies config propagation.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.StrictDurability

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfg : ClusterConfig := {
  name := "strict-durability"
  «namespace» := "flare-strict-dur"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-strict-dur"
  debugPod := "debug-strict-dur"
  -- RocksDB image: syncWrites is a rocksdb-only knob and the stats
  -- check in test 5 requires rocksdb_sync_writes to be present.
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

def suite : TestSuite := {
  name := "strict-durability"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let ok ← waitForStable cfg 50
    if !ok then throw (IO.userError "cluster did not stabilize")
  teardown := do
    cleanupCluster cfg
  tests := [
    -- Test 1: baseline — ConfigMap exists
    { name := "pre-flight: ConfigMap exists with extra.conf key"
      run := do
        match ← kubectlGetJsonpath "configmap" s!"{cfg.name}-config" cfg.«namespace»
                  "{.data.extra\\.conf}" with
        | .ok _ => return .pass
        | .error e => return .fail s!"ConfigMap missing or unreadable: {e}" },

    -- Test 2: enable syncWrites → operator renders "rocksdb-sync-writes = true"
    { name := "patch spec.rocksdb.syncWrites=true is propagated"
      run := do
        let patch := "{\"spec\":{\"rocksdb\":{\"syncWrites\":true}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          let (found, content) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-sync-writes = true" 60
          if found then return .pass
          else return .fail s!"ConfigMap missing rocksdb-sync-writes=true; actual: {content}" },

    -- Test 3: flip back to false → stale "true" must be gone, "false" present
    { name := "patching syncWrites=false cleanly replaces stale value"
      run := do
        let patch := "{\"spec\":{\"rocksdb\":{\"syncWrites\":false}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          let (found, content) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-sync-writes = false" 60
          if !found then
            return .fail s!"ConfigMap did not reflect syncWrites=false; actual: {content}"
          if containsSubstr content "rocksdb-sync-writes = true" then
            return .fail s!"Stale rocksdb-sync-writes=true still present; actual: {content}"
          return .pass },

    -- Test 4: cross-field preservation with walTtlSeconds
    { name := "syncWrites + walTtlSeconds coexist in extra.conf"
      run := do
        let patch := "{\"spec\":{\"rocksdb\":{\"syncWrites\":true,\"walTtlSeconds\":900}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ =>
          -- Wait for the integer field first
          let (foundTtl, content) ← waitForConfigLine cfg.name cfg.«namespace»
            "rocksdb-wal-ttl-seconds = 900" 60
          if !foundTtl then
            return .fail s!"walTtlSeconds missing; actual: {content}"
          if !containsSubstr content "rocksdb-sync-writes = true" then
            return .fail s!"syncWrites was clobbered by second patch; actual: {content}"
          return .pass },

    -- Test 5: flared stats reflect the sync-writes setting (best-effort)
    { name := "flared stats expose rocksdb_sync_writes"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        match ips.head? with
        | none => return .fail "no flared pod IPs"
        | some ip =>
          let stats ← flaredStats cfg.debugPod cfg.«namespace» ip cfg.flarePort
          if !containsSubstr stats "rocksdb_" then
            return .skip "flared image does not expose rocksdb_* stats (not compiled with RocksDB)"
          -- After test 4 syncWrites is true, but stats may report it as "1" or "true"
          -- depending on flared's formatting. Accept either.
          if containsSubstr stats "rocksdb_sync_writes 1" ||
             containsSubstr stats "rocksdb_sync_writes true" then
            return .pass
          else
            return .fail s!"flared stats did not show rocksdb_sync_writes=1/true; stats:\n{stats}" }
  ]
}

end FlareOperator.E2E.Tests.StrictDurability
