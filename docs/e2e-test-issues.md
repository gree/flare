# E2E Test Issues

Last updated: 2026-04-13

## Summary

- **Total**: 76 tests across 11 suites
- **Original failures**: 7 (tests 25, 26, 40, 45, 51, 52, 53)
- **New suites added**: wal-retention-config (G10), strict-durability (G11), wal-bandwidth-throttle (G12)

## Original Failing Tests (from CI)

### Group 1: scale-out-slave (tests 25, 26)

| # | Test | Failure |
|---|------|---------|
| 25 | `6 nodes registered with operator` | TIMEOUT 180s — not all 6 nodes registered |
| 26 | `new slaves assigned (Prepare state)` | P0 has 1 slave, P1 has 1 slave (expected 2 each) |

**Fix** (committed `106b723`): removed `!isPartitionReconstructing` throttle from slave assignment.

### Group 2: Migration stuck at Dumping (tests 40, 45)

| # | Suite | Test | Failure |
|---|-------|------|---------|
| 40 | scale-in-master | `migrationPhase transitions to Forwarding` | TIMEOUT — stuck at Dumping |
| 45 | replace-nodes | `migration reaches Forwarding` | TIMEOUT — stuck at Dumping |

**Fix** (committed `c731039`): added ConfigMap recovery in `.Dumping` phase.

### Group 3: cluster-replication ConfigMap (tests 51, 52, 53)

| # | Test | Failure reason |
|---|------|----------------|
| 51 | `ConfigMap contains cluster-replication settings` | ConfigMap missing replication settings |
| 52 | `migrationPhase transitions to Forwarding` | TIMEOUT — did not reach Forwarding |
| 53 | `ConfigMap updated to forward mode` | ConfigMap not in forward mode |

**Root cause**: `handleClusterReplication` was only called from the legacy `reconcileOnce` path, not from `reconcileOnceFSM` (the active production path). Fixed in `e2ccfab`.

## New RocksDB Test Suites (G10-G12)

### G10: wal-retention-config (5 tests) — VERIFIED

Tests `spec.rocksdb.walTtlSeconds` and `walSizeLimitMb` propagation from CRD to ConfigMap.

| # | Test | Live result |
|---|------|-------------|
| 1 | ConfigMap exists | PASS |
| 2 | walTtlSeconds → ConfigMap | PASS |
| 3 | walSizeLimitMb + cross-field preservation | PASS |
| 4 | Re-render on value change | PASS |
| 5 | RocksDB backend active (rocksdb_master_id in stats) | PASS |

### G11: strict-durability (5 tests) — NOT YET RUN LIVE

Tests `spec.rocksdb.syncWrites` (boolean field) propagation. Same `handleRocksdbConfig` path as G10, exercises the `Option Bool` rendering path.

### G12: wal-bandwidth-throttle (5 tests) — NOT YET RUN LIVE

Tests `spec.rocksdb.walSyncBwlimit` and `walSyncInterval` propagation. Includes an explicit-zero test (distinguishes "inherit cluster-wide setting" from "unset") and a flared stats assertion (`rocksdb_wal_sync_bwlimit` IS exposed in stats and updated by `ini_option::reload`).

## Remaining Test Proposals (not yet implemented)

| # | Name | Description | Difficulty |
|---|------|-------------|------------|
| G1 | WAL incremental sync | Slave restart within WAL TTL → `rocksdb_wal_sync_success` increments | Medium |
| G2 | WAL purged fallback | Slave down > TTL → `rocksdb_wal_sync_lsn_purged` > 0 | Medium |
| G5 | Resync failure self-demote | Consecutive failures → `state_down`, data preserved | High |
| G7 | Orphan scan/purge | Failover + rejoin → orphan_scan/orphan_purge admin commands | High |
| G3 | Zombie master | Network partition → failover → ex-master returns as role_proxy | Very high |
| G4 | master_id mismatch | RocksDB wipe → mismatch detection → full dump | High |

## Production Hardening (committed `e749c06`)

Issues discovered during live testing that affect production deployments:

### 1. Prepare-state nodes excluded from dead detection

Previously `detectDeadNodes` only excluded Proxy and Down nodes. A node in Prepare (actively reconstructing 100 GB+ data) whose pod briefly disappeared from the K8s pod list could trigger unnecessary failover, wasting hours of reconstruction work. Now Prepare nodes are excluded.

### 2. Startup grace period increased (30s → 120s)

RocksDB-backed nodes with large datasets take 30-60s to open the database and send `node add`. The previous 30s grace period was too aggressive — nodes that hadn't registered yet were invisible to the operator, causing premature role assignments.

### 3. E2E node registration timeout increased (120s → 300s)

On loaded machines or with large datasets, not all nodes register within 120s.

### Design note: reconstruction can take days

Production environments with 100 GB+ datasets can have reconstruction times of hours to a full day. The operator's design handles this correctly:

- Reconstructing nodes stay in **Prepare** state until flared sends `node state ready`
- `detectDeadNodes` skips Prepare nodes (pod must genuinely disappear for failover)
- No hardcoded timeout on how long a node can stay in Prepare
- The operator does not interfere with ongoing reconstruction

## Infrastructure Changes

| Component | Description |
|---|---|
| `Dockerfile.flare-node-rocksdb` | RocksDB-enabled flared image with ldd sanity check |
| `.dockerignore` | Prevents Nix-built host binary from shipping into Docker images |
| `ClusterConfig.storageBackend` | E2E selector: "tch" (default) or "rocksdb" |
| ConfigMap mount | StatefulSet mounts `{cluster}-config` at `/etc/flared/extra.conf` |
| `applyYaml` strict mode | Fails fast with diagnostics instead of silently swallowing errors |

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
