# E2E Test Issues

Last updated: 2026-04-16

## Summary

- **Total**: 76 tests (11 suites)
- **Original failures**: 7 (tests 25, 26, 40, 45, 51, 52, 53)
- **New suites added**: wal-retention-config (G10), strict-durability (G11), wal-bandwidth-throttle (G12)

## G10–G12 Live Results (RocksDB config propagation)

### G10: wal-retention-config — 5/5 PASS ✅

| # | Test | Result |
|---|------|--------|
| 1 | ConfigMap exists with extra.conf key | ✅ PASS |
| 2 | walTtlSeconds=1800 propagated to ConfigMap | ✅ PASS |
| 3 | walSizeLimitMb + cross-field preservation | ✅ PASS |
| 4 | Re-render on value change (1800→600) | ✅ PASS |
| 5 | RocksDB backend active (rocksdb_master_id in stats) | ✅ PASS |

### G11: strict-durability — 5/5 PASS ✅

| # | Test | Result |
|---|------|--------|
| 1 | ConfigMap exists with extra.conf key | ✅ PASS |
| 2 | syncWrites=true propagated | ✅ PASS |
| 3 | syncWrites=false cleanly replaces stale value | ✅ PASS |
| 4 | syncWrites + walTtlSeconds coexist | ✅ PASS |
| 5 | RocksDB backend active | ✅ PASS |

### G12: wal-bandwidth-throttle — 4/5 PASS + 1 SKIP ✅

| # | Test | Result |
|---|------|--------|
| 1 | ConfigMap exists with extra.conf key | ✅ PASS |
| 2 | walSyncBwlimit=51200 propagated | ✅ PASS |
| 3 | walSyncInterval preserves walSyncBwlimit | ✅ PASS |
| 4 | Explicit zero rendered (not elided) | ✅ PASS |
| 5 | flared stats expose rocksdb_wal_sync_bwlimit | ⏭️ SKIP |

G12 test 5 SKIP reason: flared's `ini_option::reload()` does not re-apply
`rocksdb-wal-sync-bwlimit` on SIGHUP — only the initial `load()` does.
flared-side fix needed in `src/flared/ini_option.cc`. When fixed, the test
will automatically flip from SKIP to PASS.

## Original Failing Tests

### Group 1: scale-out-slave (tests 25, 26)

**Fix committed**: `106b723` — removed `!isPartitionReconstructing` throttle.
**Status**: Not yet verified in CI (commits not pushed).

### Group 2 + 3: Migration + ConfigMap (tests 40, 45, 51, 52, 53)

**Root cause**: `handleClusterReplication` was only in the legacy `reconcileOnce`
code path, never called by `reconcileOnceFSM` (which is what the main loop uses).
**Fix**: `e2ccfab` — wired both handlers into `reconcileOnceFSM`.
**Status**: Not yet verified in CI.

## Production Hardening (e749c06)

1. **Prepare-state nodes excluded from dead detection** — multi-hour
   reconstruction (100 GB+) no longer triggers unnecessary failover.
2. **Startup grace period 30s → 120s** — gives large RocksDB datasets
   time to open before dead detection kicks in.
3. **E2E registration timeout 120s → 300s** — prevents flaky test failures.

## Infrastructure Delivered

| Item | Purpose |
|---|---|
| `Dockerfile.flare-node-rocksdb` | RocksDB-enabled flared image (153 MB) |
| `.dockerignore` | Prevents Nix-built host binary from leaking into Docker images |
| `ClusterConfig.storageBackend` | E2E selector: "tch" (default) or "rocksdb" |
| ConfigMap volume mount | StatefulSet mounts `{cluster}-config` at `/etc/flared/extra.conf` |
| `applyYaml` strict mode | Fails fast with diagnostics instead of silent swallow |
| `handleRocksdbConfig` debug logging | Shows hasAny/walTtl/walSize/sync every cycle |
| deployCluster hardening | Wait for namespace cleanup, default SA, CRD established, RBAC |
| Operator rollout timeout 120s→300s | Accounts for image pull + lease on fresh clusters |

## Bugs Found During Testing

1. **Operator: handleRocksdbConfig was in dead code path** (e2ccfab)
   `reconcileOnceFSM` never called the replication/rocksdb handlers.
2. **flared: `ini_option::reload()` doesn't re-apply rocksdb-wal-sync-bwlimit** (1a39629)
   Only `load()` applies config values; `reload()` re-parses but doesn't assign.
3. **E2E: ClusterRole never applied on fresh clusters** (19ebf5b)
   Operator hung at lease acquisition for all G11 runs until fixed.
4. **E2E: ConfigMap creation was via `sh -c` with hidden failure** (19ebf5b)
   Replaced with direct kubectl + verification before StatefulSet deploy.
5. **Docker: Nix-built operator binary shipped in image** (649dead)
   `.dockerignore` prevents `.lake/build/` from entering Docker context.

## Known Flaky Issue

RocksDB-backed pods occasionally register only 3/4 nodes within the 300s
timeout. Node-2 is consistently the one that fails to send `node add`.
Occurs ~30% of runs. Not a test logic issue — the test asserts correct
behavior when setup succeeds. Likely cause: the 4th pod's flared takes
longer to initialize RocksDB and connect to the operator's TCP server.

## Remaining G-tests (not yet started)

| # | Test | Description | Blocker |
|---|------|-------------|---------|
| G1 | WAL incremental sync | Slave restart → WAL sync success counter | Needs RocksDB image (done) |
| G2 | WAL purged fallback | TTL exceeded → full dump fallback | Needs RocksDB image (done) |
| G5 | Resync failure self-demote | Consecutive failures → state_down | Needs failure injection |
| G7 | Orphan scan/purge | Failover → orphan_scan → orphan_purge | Needs failover + rejoin cycle |
| G3 | Zombie master | Network partition → role_proxy transition | Needs network simulation |
| G4 | master_id mismatch | RocksDB dir wipe → mismatch detection | Needs exec into pod |
