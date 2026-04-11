# E2E Test Issues

Last updated: 2026-04-08

## Summary

- **Total**: 61 tests
- **Passed**: 54
- **Failed**: 7 (tests 25, 26, 40, 45, 51, 52, 53)
- **Result**: FAIL

## Failing Tests

### Group 1: scale-out-slave (tests 25, 26)

| # | Test | Failure |
|---|------|---------|
| 25 | `6 nodes registered with operator` | TIMEOUT 180s — not all 6 nodes registered |
| 26 | `new slaves assigned (Prepare state)` | P0 has 1 slave, P1 has 1 slave (expected 2 each) |

**Scenario**: Scaling replicas 2→3 (pods 4→6). New pods come up, but the operator only assigns 1 slave per partition instead of 2.

**Suspected cause**: Throttling logic in `flare_operator/FlareOperator/StateMachine/Reconciler.lean` (`findPartitionForSlave`) refuses to assign a new slave when `isPartitionReconstructing` is true, which blocks legitimate scale-out.

**Proposed fix** (committed locally, not yet verified in CI): remove the `!isPartitionReconstructing state i` check from the slave-assignment condition.

---

### Group 2: Migration stuck at Dumping (tests 40, 45)

| # | Suite | Test | Failure |
|---|-------|------|---------|
| 40 | scale-in-master | `migrationPhase transitions to Forwarding` | TIMEOUT 180s — stuck at Dumping |
| 45 | replace-nodes | `migration reaches Forwarding` | TIMEOUT 240s — stuck at Dumping |

**Scenario**: Migration enters the `Dumping` phase successfully but never advances to `Forwarding`.

**Suspected cause**: Same root cause as Group 3 (ConfigMap not persisted correctly during Dumping phase, so flared never receives forward-mode config).

---

### Group 3: cluster-replication ConfigMap (tests 51, 52, 53)

| # | Test | Failure reason |
|---|------|----------------|
| 51 | `ConfigMap contains cluster-replication settings` | ConfigMap missing replication settings |
| 52 | `migrationPhase transitions to Forwarding` | TIMEOUT — did not reach Forwarding |
| 53 | `ConfigMap updated to forward mode` | ConfigMap not in forward mode |

**Scenario**: Operator reaches `Dumping` (test 50 passes) but the ConfigMap is empty or missing `cluster-replication` settings, so flared never switches to forward mode and the phase never advances.

**Suspected cause**: `handleClusterReplication` in `flare_operator/FlareOperator/Main.lean` writes the ConfigMap in phase `.None`, but during `.Dumping` (after operator restart or re-reconcile) the ConfigMap can be missing or lack replication settings. There is no recovery path.

**Proposed fix** (committed locally, not yet verified in CI): in the `.Dumping` branch, read the ConfigMap; if missing or missing the `cluster-replication` key, re-run `updateFlaredReplicationConfig` and send SIGHUP to pods.

---

## Root Cause Analysis

Two distinct bugs:

1. **Slave assignment throttling** (tests 25–26): the reconciler treats scale-out as reconstruction and refuses to assign additional slaves.
2. **ConfigMap persistence for cluster replication** (tests 40, 45, 51–53): no recovery path if the ConfigMap is missing/incomplete while already in `Dumping` phase.

## Notable Observation

**No `[DEBUG]` / `[TRACE]` logs appear in CI output** despite being added locally. This indicates the Docker image that CI builds does **not** contain the recent fixes — the commits are local only.

## Fix Status

| Fix | Local commit | Pushed to remote | Verified in CI |
|---|---|---|---|
| Remove slave throttling | `106b723` | ❌ | ❌ |
| ConfigMap recovery in Dumping | `c731039` | ❌ | ❌ |
| Debug logging | `974f001` | ❌ | ❌ |

## Next Actions

1. Push local commits to remote so CI rebuilds the image with the fixes.
2. Re-run E2E suite and verify scale-out-slave (25–26) passes.
3. Inspect new `[DEBUG]` logs for the migration/cluster-replication failures to confirm the ConfigMap recovery path fires.
4. If tests 40/45/51–53 still fail, use debug logs to diagnose remaining issues.
