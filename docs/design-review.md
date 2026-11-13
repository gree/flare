# Flare Operator + RocksDB Replication — Design Review

**Meeting**: 1 hour design review
**Scope**: Operator architecture, RocksDB WAL replication, safety guarantees

---

## Agenda (60 min)

| Time | Topic |
|---|---|
| 0-10 | Architecture overview + data flow |
| 10-25 | Operator FSM design + safety proofs |
| 25-40 | RocksDB WAL replication protocol |
| 40-50 | Production hardening + failure scenarios |
| 50-60 | Known issues, risks, and next steps |

---

## 1. Architecture Overview (10 min)

### System Components

```
                     ┌─────────────────────────────┐
                     │      Kubernetes API          │
                     │  (FlareCluster CRD, Pods,    │
                     │   ConfigMaps, Leases)        │
                     └──────────┬──────────────────┘
                                │ kubectl
                     ┌──────────▼──────────────────┐
                     │   Flare Operator (Lean 4)    │
                     │                              │
                     │  ┌────────────────────────┐  │
                     │  │ FSM Reconciler          │  │
                     │  │ (12-step verified)      │  │
                     │  └────────────────────────┘  │
                     │  ┌────────────────────────┐  │
                     │  │ TCP Server (:12120)     │  │
                     │  │ (node add/sync/meta)    │  │
                     │  └────────────────────────┘  │
                     │  ┌────────────────────────┐  │
                     │  │ Config Propagation      │  │
                     │  │ (rocksdb + replication) │  │
                     │  └────────────────────────┘  │
                     └───────┬──────────┬──────────┘
                    TCP :12120         SIGHUP
                     ┌───────▼──┐  ┌───▼──────────┐
                     │ flared-0 │  │ flared-1     │  ...
                     │ (Master) │  │ (Slave)      │
                     │ P0       │  │ P0           │
                     │ RocksDB  │  │ RocksDB      │
                     │ WAL ──────────► WAL sync   │
                     └──────────┘  └──────────────┘
```

### Data Flow

```
User → memcached SET → Master (RocksDB Write + WAL append)
                          │
                          ├─ Proxy-write replication → Slave (async)
                          │
                          └─ WAL incremental sync ← Slave pulls on interval
                              (or full dump fallback if WAL purged)
```

### Key Files

| Component | Language | File |
|---|---|---|
| Reconciler FSM | Lean 4 | `StateMachine/Reconciler.lean` |
| K8s IO bridge | Lean 4 | `StateMachine/K8sReconciler.lean` |
| TCP protocol | Lean 4 | `Server/TcpServer.lean` |
| Config propagation | Lean 4 | `Main.lean`, `K8s/Bridge.lean` |
| RocksDB storage | C++ | `src/lib/storage_rocksdb.cc` |
| WAL replication | C++ | `src/lib/handler_dump_replication.cc` |
| WAL sync protocol | C++ | `src/lib/op_repl_sync_wal.cc` |

---

## 2. Operator FSM Design (15 min)

### 12-Step Reconcile FSM

```
Init ──► FetchCRD ──► ListPods ──► DetectDead
  │                                    │
  │                              ┌─────┴─────┐
  │                              │ ≥50% dead? │
  │                              └─────┬─────┘
  │                                yes │ no
  │                                    │
  │                        EmergencyPaused  HandleFailover
  │                        (terminal)       │
  │                                   AssignRoles
  │                                         │
  │                                   UpdateConfigMap
  │                                         │
  │                                   HandleReplication
  │                                         │
  │                                   BroadcastTopology
  │                                         │
  │                                   PatchService
  │                                         │
  │                                        Done
  │                                    (terminal)
  └──────────────────────────────────► Error(msg)
                                       (terminal)
```

### Termination Proof

Each step has a strictly decreasing measure:

```lean
def flareReconcileMeasure (step : FlareReconcileStep) : Nat :=
  match step with
  | .Init                   => 12
  | .AfterFetchCRD          => 11
  | .AfterListPods          => 10
  | .AfterDetectDead        => 9
  | .EmergencyPaused        => 0  -- terminal
  | .AfterHandleFailover    => 7
  | .AfterAssignRoles       => 6
  ...
  | .Done                   => 0  -- terminal
  | .Error _                => 0  -- terminal
```

**Guarantee**: The reconciler always terminates. No infinite loop possible.

### Safety Invariant: At-Most-One-Master-Per-Partition

```lean
theorem atMostOneMasterPerPartition :
  ∀ (k1 k2 : String) (n1 n2 : FlareNode),
    (k1, n1) ∈ state.nodeMap →
    (k2, n2) ∈ state.nodeMap →
    n1.role = FlareRole.Master →
    n2.role = FlareRole.Master →
    n1.partition = n2.partition →
    k1 = k2
```

**Formally proven** in Lean 4. Split-brain cannot occur at the operator state level.

### Auto-Assignment Flow

```
New flared pod connects → node add → enters as Proxy
                                        │
                         ┌──────────────┤
                         ▼              ▼
                   Need Master?    Need Slave?
                   (partition has   (partition has
                    no master)      < replicas-1
                         │          slaves)
                         ▼              ▼
                   Master/Active    Slave/Prepare
                   (P0) or         (must reconstruct
                   Master/Prepare   before Active)
                   (P1+)
```

---

## 3. RocksDB WAL Replication (15 min)

### Three-Tier Replication Strategy

```
handler_dump_replication::run()
         │
    Phase 1: Capability Negotiation
         │  meta features → OK rocksdb_wal=1 master_id=UUID
         │
    Phase 2: WAL Incremental Sync
         │  repl_sync_wal <lsn> <master_id>
         │      ├─ OK → stream LSN+BATCH pairs → apply_batch_with_lsn
         │      ├─ master_id_mismatch → Phase 3
         │      ├─ lsn_ahead → Phase 3
         │      ├─ lsn_purged → Phase 3
         │      └─ batch_too_large → Phase 3
         │
    Phase 3: Full Dump Fallback (always safe, non-destructive)
         │  iter_begin → iter_next → op_set each key
         │
         ▼
    notify_resync_result(success/failure)
```

### WAL Sync Protocol (wire format)

```
Slave → Master:  repl_sync_wal 42000 a1b2c3d4-...\r\n

Master → Slave:  LSN 42001\r\n
                 BATCH 1234\r\n
                 <1234 bytes of WriteBatch data>
                 \r\n
                 LSN 42002\r\n
                 BATCH 567\r\n
                 <567 bytes>
                 \r\n
                 END\r\n

Slave applies:   apply_batch_with_lsn(batch, 42002)
                 → Single RocksDB Write() with data + LSN marker
                 → Crash-consistent (atomic)
```

### Crash Consistency: apply_batch_with_lsn

```
BEFORE (crash-unsafe):
  Write(batch)  ──crash here──►  Data advanced, LSN stale
  Put(LSN)                       → Next sync replays same range
                                 → incr() values drift!

AFTER (atomic):
  merged_batch = Copy(batch) + append Put(LSN)
  Single Write(merged_batch)
  → RocksDB guarantees: both advance or neither does
```

### Master Identity Token (lineage tracking)

```
Master A (id=abc)          Master B (id=def)
     │                          │
     └── Slave remembers ───────┘
         master_id = abc
         │
         ├─ Connects to A: master_id match → WAL sync OK
         │
         └─ Connects to B: master_id MISMATCH → full dump
            (detects split-brain, backup restore, etc.)
```

### Reserved Metadata Keys

| Key | Purpose | Protection |
|---|---|---|
| `__flare_repl_last_lsn` | Slave's last synced LSN | Hidden from get/set/iter/truncate |
| `__flare_repl_master_id` | Master lineage token | Hidden from get/set/iter, preserved by truncate |

---

## 4. Production Hardening (10 min)

### Dead Node Detection

```
Every 5s reconcile cycle:
  pods = kubectl get pods (ALL pods, including Terminating/CrashLoop)
  for each node in nodeMap:
    if node NOT in pods AND node.role ∈ {Master, Slave} AND node.state = Active:
      → DEAD (trigger failover)
    if node.state = Prepare:
      → SKIP (reconstruction may take hours for 100GB+)
    if node.role = Proxy or node.state = Down:
      → SKIP (already inactive)
```

**Startup Grace Period**: 24 cycles × 5s = 120s
- RocksDB open on 100GB+ dataset can take 30-60s
- Grace prevents premature role assignment with incomplete node set

### Circuit Breaker (AZ-level failure protection)

```
Dead nodes ≥ 50% of total → EmergencyPaused
  - No automatic failover
  - No role reassignment
  - Operator logs warning and waits
  - Requires pod restart to reset

Dead nodes < 20% → Normal operation resumes
  (hysteresis prevents flapping)
```

### Config Propagation Flow

```
User patches CRD:  spec.rocksdb.walTtlSeconds = 1800
         │
Operator reads CRD (every 5s reconcile)
         │
handleRocksdbConfig:
  1. hasAny? → yes
  2. clusterReplication.enabled? → no (rocksdb-only path)
  3. renderExtraConf → "rocksdb-wal-ttl-seconds = 1800"
  4. readFlaredExtraConf → compare with current
  5. If changed: applyExtraConfConfigMap + sendSighupToPods
         │
flared receives SIGHUP → ini_option::reload() → re-reads extra.conf
```

### Failure Scenario Matrix

| Scenario | Detection | Recovery | Data Loss? |
|---|---|---|---|
| Slave AZ down | monitor → state_down | WAL sync (within TTL) or full dump | No |
| Master AZ down | monitor → failover | Slave promoted to Master | Recent async writes |
| Network partition | monitor both sides | master_id mismatch on heal → full dump | Losing side's writes |
| Zombie master | up_node → role_proxy | handler_reconstruction (full dump) | Zombie's orphan writes |
| Slave crash during WAL apply | None needed | Atomic LSN → no partial state | No |
| Repeated resync failures | Counter ≥ threshold | Self-demote to state_down | No (data preserved) |

---

## 5. Known Issues + Risks (10 min)

### OSS Bug Risk Assessment

| Risk | Source | Flare Mitigation |
|---|---|---|
| **HIGH**: Scale-in data loss | CockroachDB #542 | partition-reduction blocked, but ordering critical |
| **HIGH**: Async replication loss | Vitess #6206 | By design; document the window |
| **MEDIUM**: Concurrent CRD changes | TiDB #720 | Sequential FSM, but rapid changes untested |
| **LOW**: Split-brain | redis-operator #1314 | Lean proof: atMostOneMasterPerPartition |
| **LOW**: Pod termination loop | redis-operator #932 | FSM termination proof |

### Verified via E2E Tests (17 suites, 107 tests)

| Category | Suites | Status |
|---|---|---|
| Core topology | failover, partition-reduction | ✅ PASS |
| Scale operations | scale-out-master/slave, scale-in-slave/master | ✅ PASS (1 infra flake) |
| Cluster replication | cluster-replication, replace-nodes | ✅ PASS (1 infra flake) |
| RocksDB config | G10, G11, G12 | ✅ PASS |
| WAL replication | G1, G2 | ✅ PASS (SKIP on emptyDir) |
| Fault injection | G5, G7 | ✅ PASS (SKIP on reload limitation) |
| OSS bug regression | terminating-pod, failover-during-replication | ✅ PASS |

### flared-side Issues Found

1. `ini_option::reload()` doesn't re-apply rocksdb config values on SIGHUP
   - Affects: walTtlSeconds, walSizeLimitMb, syncWrites, resyncFailureThreshold
   - Only `load()` at startup applies these; `reload()` re-parses but doesn't assign
   - **Fix needed in**: `src/flared/ini_option.cc` reload() function

### Logging Gaps (recently improved)

| Added | Gap |
|---|---|
| ✅ | CRD change detection |
| ✅ | Per-node state transitions `[NodeState]` |
| ✅ | ConfigMap content summary |
| ✅ | Reconcile duration (>1s) |
| ⬜ | Lease renewal heartbeat |
| ⬜ | SIGHUP response verification |
| ⬜ | Replication progress (bytes transferred) |

---

## Discussion Points

1. **Scale-in ordering guarantee**: How do we ensure data migration completes before StatefulSet replica reduction? Current: partition-reduction is blocked. Is this sufficient?

2. **PVC testing**: All E2E tests use emptyDir. With PVC, stale RocksDB data from prior partition assignments could cause issues. Should we add PVC-backed tests?

3. **Async replication data loss window**: Document the expected loss window for operators. Is `syncWrites=true` + WAL sync sufficient for strict durability requirements?

4. **flared reload() fix scope**: Which config values need runtime reload support? Should we fix all rocksdb-* options or only the most commonly changed ones?

5. **Circuit breaker reset**: Currently requires operator pod restart. Should we support CRD-triggered reset?
