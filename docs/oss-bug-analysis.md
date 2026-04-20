# OSS Bug Analysis for Flare Operator

Last updated: 2026-04-19

## Similar OSS Projects

| Project | Similarity | Key overlap |
|---|---|---|
| OT-CONTAINER-KIT/redis-operator | Highest | Shard-based master/slave, operator failover |
| spotahome/redis-operator | High | Sentinel HA, operator-managed topology |
| Vitess (vitessio/vitess) | High | WAL-based replication, resharding |
| TiDB Operator (pingcap/tidb-operator) | Medium | RocksDB backend (TiKV), operator scaling |
| CockroachDB Operator | Medium | Range partitioning, decommission |
| Pinterest Rocksplicator (archived) | Technical closest | RocksDB WAL replication, partitioned master/slave |

## Risk Assessment

### HIGH risk

| Bug | Source | Issue | Flare status |
|---|---|---|---|
| Scale-in: replica reduced before data migration completes | CockroachDB | [#542](https://github.com/cockroachdb/cockroach-operator/issues/542) | partition-reduction is blocked, but StatefulSet replica count reduction ordering is critical |
| Async replication data loss on failover | Vitess, spotahome | [#6206](https://github.com/vitessio/vitess/issues/6206), [#205](https://github.com/spotahome/redis-operator/issues/205) | By design (async). Document the data loss window |
| Concurrent scale-out/in race | TiDB | [#720](https://github.com/pingcap/tidb-operator/issues/720) | Rapid CRD changes could cause intermediate state inconsistency |

### MEDIUM risk

| Bug | Source | Issue | Flare status |
|---|---|---|---|
| Terminating pod not detected as dead | redis-operator | [#1544](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1544) | detectDeadNodes should verify Terminating = dead |
| Stale PVC data on scale-in/out | redis-operator | [#1407](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1407) | Only tested with emptyDir, not PVC |
| Failover during cluster-replication | Vitess | [#8909](https://github.com/vitessio/vitess/issues/8909) | FSM handles separately but interaction untested |
| Replica disconnected but reports healthy | Vitess | [#9788](https://github.com/vitessio/vitess/issues/9788) | Health probe is TCP only, not replication-aware |
| Full cluster restart: empty realMaster crash loop | redis-operator | [PR #1720](https://github.com/OT-CONTAINER-KIT/redis-operator/pull/1720) | Circuit breaker helps, but all-dead recovery path needs validation |
| Large dataset decommission takes hours/days | CockroachDB | [#73763](https://github.com/cockroachdb/cockroach/issues/73763) | WAL sync mitigates, but full dump fallback can be slow for 100GB+ |

### LOW risk (Flare has mitigations)

| Bug | Source | Flare mitigation |
|---|---|---|
| Split-brain / double master | redis-operator [#1314](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1314) | Lean proof: `atMostOneMasterPerPartition` |
| No master after failover | redis-operator [#1403](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1403) | `findPartitionNeedingMaster` scans every cycle |
| Pod termination loop | redis-operator [#932](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/932) | FSM termination proof (`flareReconcileMeasure`) |
| Operator crash recovery stale state | redis-operator [PR #1720](https://github.com/OT-CONTAINER-KIT/redis-operator/pull/1720) | State rebuilt from K8s API each cycle |
| Topology cache staleness | Vitess [#8465](https://github.com/vitessio/vitess/issues/8465) | Per-cycle broadcast to all nodes |
| Old master overwrites promoted slave | spotahome [#95](https://github.com/spotahome/redis-operator/issues/95) | Rejoining node enters as Proxy, not Master |
| Duplicated store address | TiDB [#385](https://github.com/pingcap/tidb-operator/issues/385) | StatefulSet guarantees unique pod names |

## Logging Gap Analysis

### CAN debug from logs

- Dead node detection (which node, count)
- Failover actions (slave promotion, reasons)
- Cluster replication phase transitions (None→Dumping→Forwarding)
- RocksDB config byte count applied
- Lease acquisition/loss
- Topology version changes
- Partition reduction blocking

### CANNOT debug from logs

| Gap | Impact | Priority |
|---|---|---|
| ConfigMap actual content | Cannot verify what config was written | HIGH |
| Per-node state transitions (Proxy→Master→Down) | Cannot trace individual node lifecycle | HIGH |
| CRD change detection | Cannot see when partition/replica count changed | HIGH |
| Reconcile cycle duration | Cannot detect slow reconciles | MEDIUM |
| Replication progress (Dumping phase) | Cannot see data transfer progress | MEDIUM |
| SIGHUP response from flared | Cannot verify config was applied | MEDIUM |
| Lease renewal success | No heartbeat during normal operation | MEDIUM |
| Service routing verification | Only errors logged, not success | LOW |
| Pod registration timing | Cannot see when node add arrives | LOW |

## Recommended Actions

### Logging improvements

1. Log ConfigMap content SHA256 hash after write
2. Log per-node state transitions
3. Log CRD spec changes (diff from previous)
4. Log reconcile cycle duration
5. Log lease renewal heartbeat periodically

### Tests added (based on OSS bugs)

| Test | Source bug | Result |
|---|---|---|
| terminating-pod-handling | redis-operator [#1544](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1544) | ✅ 5/5 PASS — Flareは正しく処理 |
| failover-during-replication | Vitess [#8909](https://github.com/vitessio/vitess/issues/8909) | ✅ 6/6 PASS — Dumping中のfailoverで回復可能 |

### Tests remaining (based on OSS bugs)

1. PVC-backed storage tests (redis-operator #1407)
2. Concurrent CRD changes (TiDB #720)
3. All-dead partition recovery (redis-operator PR #1720)

### Logging improvements implemented

1. ✅ ConfigMap content summary (byte count, line count, first line)
2. ✅ Per-node state transitions `[NodeState]`
3. ✅ CRD change detection (partitions/replicas diff)
4. ✅ Reconcile duration + cluster summary (when >1s)
5. ⬜ Lease renewal heartbeat (not yet added)
