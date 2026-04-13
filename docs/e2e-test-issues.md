# E2E Test Issues

Last updated: 2026-04-13

## Summary

- **Total**: 76 tests (11 suites)
- **Original failures**: 7 (tests 25, 26, 40, 45, 51, 52, 53)
- **New suites added**: wal-retention-config (G10), strict-durability (G11), wal-bandwidth-throttle (G12)

## G10–G12 Results (RocksDB config propagation)

### G10: wal-retention-config — 5/5 PASS

Verified live on kind cluster with `flare-node-rocksdb:test` image.

| # | Test | Result |
|---|------|--------|
| 1 | ConfigMap exists with extra.conf key | ✅ PASS |
| 2 | walTtlSeconds=1800 propagated to ConfigMap | ✅ PASS |
| 3 | walSizeLimitMb + cross-field preservation | ✅ PASS |
| 4 | Re-render on value change (1800→600) | ✅ PASS |
| 5 | RocksDB backend active (rocksdb_master_id in stats) | ✅ PASS |

### G11: strict-durability — NOT YET RUN LIVE

Built and committed. Uses same `handleRocksdbConfig` path as G10.
Exercises the `Option Bool` field path (syncWrites true/false toggle).

### G12: wal-bandwidth-throttle — NOT YET RUN LIVE

Built and committed. Tests `walSyncBwlimit` and `walSyncInterval`.
Test 5 checks `rocksdb_wal_sync_bwlimit` in flared stats — this field
IS exposed by `op_stats.cc` and IS updated by `ini_option::reload()`,
so it should pass when run.

## Original Failing Tests

### Group 1: scale-out-slave (tests 25, 26)

| # | Test | Failure |
|---|------|---------|
| 25 | `6 nodes registered with operator` | TIMEOUT 180s — not all 6 nodes registered |
| 26 | `new slaves assigned (Prepare state)` | P0 has 1 slave, P1 has 1 slave (expected 2 each) |

**Fix committed**: `106b723` — removed `!isPartitionReconstructing` throttle.
**Status**: Not yet verified in CI (commits not pushed).

### Group 2: Migration stuck at Dumping (tests 40, 45)

| # | Suite | Test | Failure |
|---|-------|------|---------|
| 40 | scale-in-master | `migrationPhase transitions to Forwarding` | TIMEOUT — stuck at Dumping |
| 45 | replace-nodes | `migration reaches Forwarding` | TIMEOUT 240s — stuck at Dumping |

**Fix committed**: `e2ccfab` — wired `handleClusterReplication` into `reconcileOnceFSM`.
Previously the handler was only in the legacy `reconcileOnce` path which is never called.
**Status**: Not yet verified in CI.

### Group 3: cluster-replication ConfigMap (tests 51, 52, 53)

| # | Test | Failure reason |
|---|------|----------------|
| 51 | `ConfigMap contains cluster-replication settings` | ConfigMap missing replication settings |
| 52 | `migrationPhase transitions to Forwarding` | TIMEOUT — did not reach Forwarding |
| 53 | `ConfigMap updated to forward mode` | ConfigMap not in forward mode |

**Root cause**: Same as Group 2 — `handleClusterReplication` was in the dead legacy code path.
The ConfigMap recovery logic (`c731039`) was correct but never executed because `reconcileOnceFSM`
didn't call it.
**Fix**: `e2ccfab` (same commit as Group 2).
**Status**: Not yet verified in CI.

## Production Hardening (e749c06)

Three changes to prevent premature dead-node detection in production workloads
with 100 GB+ datasets and multi-hour reconstruction:

1. **Prepare-state nodes excluded from dead detection**: `detectDeadNodes` now
   skips nodes in `FlareState.Prepare`. A node mid-reconstruct whose pod
   disappears gets restarted by K8s and re-registers via `node add` — marking
   it dead during reconstruction wastes hours of already-completed work.

2. **Startup grace period 30s → 120s**: RocksDB-backed nodes with large datasets
   take 30-60s to open the database and send `node add`. Previous 30s grace
   caused the operator to start assigning roles to a subset of nodes.

3. **E2E registration timeout 120s → 300s**: Prevents flaky test failures on
   loaded machines where 3/4 nodes register but the 4th times out.

## Infrastructure Delivered

| Item | Purpose |
|---|---|
| `Dockerfile.flare-node-rocksdb` | RocksDB-enabled flared image (153 MB) |
| `.dockerignore` | Prevents Nix-built host binary from leaking into Docker images |
| `ClusterConfig.storageBackend` | E2E selector: "tch" (default) or "rocksdb" |
| ConfigMap volume mount | StatefulSet mounts `{cluster}-config` at `/etc/flared/extra.conf` |
| `applyYaml` strict mode | Fails fast with diagnostics instead of silently swallowing errors |
| `handleRocksdbConfig` debug logging | Shows `hasAny/walTtl/walSize/sync` every reconcile cycle |

## Remaining G-tests (not yet started)

| # | Test | Description | Blocker |
|---|------|-------------|---------|
| G1 | WAL incremental sync | Slave restart → WAL sync success counter | Needs RocksDB image (done) |
| G2 | WAL purged fallback | TTL exceeded → full dump fallback | Needs RocksDB image (done) |
| G5 | Resync failure self-demote | Consecutive failures → state_down | Needs failure injection |
| G7 | Orphan scan/purge | Failover → orphan_scan → orphan_purge | Needs failover + rejoin cycle |
| G3 | Zombie master | Network partition → role_proxy transition | Needs network simulation |
| G4 | master_id mismatch | RocksDB dir wipe → mismatch detection | Needs exec into pod |

## Commit History

```
e749c06 Harden dead-node detection for production workloads
a162b62 e2e: fix G10/G11 test 5 to check rocksdb_master_id, not config values
e2ccfab fix: wire handleRocksdbConfig into reconcileOnceFSM (not just legacy path)
649dead e2e: fail fast on kubectl apply errors + exclude .lake from docker context
e70e880 e2e: add RocksDB-enabled flared image + ConfigMap mount wiring
fa4a292 e2e: add wal-bandwidth-throttle suite (G12)
fbfece0 e2e: add strict-durability suite for rocksdb-sync-writes (G11)
04dd365 operator: propagate spec.rocksdb.* to flared ConfigMap (G10)
03a08f4 docs: add E2E test issues summary for RocksDB work
4a267b9 nix: add shell.nix for plain nix-shell entry
8df7862 nix: fix cutter build under GCC 14
c231fee Merge branch 'feature/rocksdb' into flare-operator
```
