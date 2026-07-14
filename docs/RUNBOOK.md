# Flare Operator Runbook

On-call procedures for the Lean-operator-managed Flare cluster. Alert names
match `deploy/monitoring/prometheus-rules.yaml` /
`helm/flare-operator/templates/prometheusrule.yaml`.

Quick orientation:
- Control plane = the operator (leader-elected, FSM tick every 5s). Data
  plane = flared pods (StatefulSet `<cluster>-nodes`). **The data plane keeps
  serving with its last topology even if the operator dies** — control-plane
  incidents are urgent but not instant data outages.
- The operator's view: `printf 'node sync\r\n' | nc <operator-svc> 12120`
  (roles: 0=master 1=slave 2=proxy; states: 0=active 1=prepare 2=down).
- Useful log greps (operator): `CIRCUIT BREAKER TRIPPED`, `LEASE FENCE`,
  `WARNING: node .* Prepare`, `Promoting Slave`, `topology changed`.
- flared data-plane greps: `reconstruction via WAL`, `truncate skipped`,
  `truncating local storage`, `master_id`.

---

## FlareMasterMissing (critical) {#master-missing}

A partition has no Active master → its key range takes no writes.

1. `node sync` (above): which partition, and what state is its former
   master in?
2. Normal failover takes < 60s after dead detection. If the alert fired,
   something blocked it:
   - **Startup grace**: within ~120s of an operator (re)start dead detection
     is off by design. If the operator just restarted, expect self-heal at
     grace end; don't intervene before that.
   - **Circuit breaker tripped** → follow [circuit-breaker](#circuit-breaker).
   - **No promotable replica** (`No Slave available for promotion` in logs):
     the partition's slaves are dead/Prepare. If pods exist with PVC data,
     they will re-register and be re-assigned; if data is lost on all
     replicas → restore from backup (docs/BACKUP_RESTORE.md).
3. Verify recovery: `node sync` shows an Active master per partition AND a
   test write succeeds through it.

## FlareCircuitBreakerTripped (critical) {#circuit-breaker}

≥ the configured fraction (default 50%) of Active nodes died at once —
suspected AZ event. The operator INTENTIONALLY pauses failover (mass
promotion during an AZ flap causes more damage than it fixes). Surviving
nodes keep serving their partitions.

1. Confirm scope: `kubectl get pods -o wide` — is a zone/nodepool gone?
   Check cloud/AZ status.
2. **Do nothing to the operator.** It re-evaluates every 5s and resumes
   automatically once the dead fraction drops below the threshold (pods
   rescheduling back is usually enough). The old log text demanding an
   operator restart was wrong and has been removed.
3. If capacity will NOT return (permanent zone loss): scale the StatefulSet
   so the surviving fraction exceeds the threshold, or (measured decision)
   lower `spec.circuitBreaker.tripThresholdPercent` to let failover proceed
   with the replicas that remain. Expect reconstruction load after resume.
4. Post-incident: verify one Active master per partition and PVC data
   intact (spot-check keys), then review
   `flare_operator_dead_nodes_detected_total`.

## FlarePrepareStuck (warning) {#prepare-stuck}

A node has been reconstructing (Prepare) beyond the watchdog threshold
(~1h). Prepare nodes never serve and are exempt from dead detection, so
nothing else will surface this.

1. Identify the pod (operator log line names it) and read its flared logs:
   look for `reconstruction via full dump`, connection errors to its source,
   or a silent stall.
2. Large datasets legitimately take hours — check `curr_items` growth via
   `printf 'stats\r\n' | nc <pod-ip> 12121`. Growing → leave it alone.
3. Genuinely stalled (source died mid-copy, no progress): delete the pod.
   It re-registers and reconstruction restarts against the current master.
   With a PVC and matching lineage the WAL path makes the retry incremental.

## FlareOperatorAbsent (critical) {#operator-down}

No operator metrics. Data plane still serves, but failover/scaling/config
propagation are dead.

1. `kubectl -n flare-system get pods -l app=flare-operator` — CrashLoop?
   Check logs; `lease lost` exits are normal single restarts (Deployment
   restarts it; a standby replica takes the lease if replicaCount ≥ 2).
2. After recovery the operator reloads state from the `<cluster>-node-map`
   ConfigMap; the cluster shape must NOT churn (verified by the
   operator-restart e2e). A fresh 120s dead-detection grace follows — factor
   it into any concurrent incident.

## FlareDeadNodeChurn (warning) {#dead-node-churn}

Repeated dead-node detections without a breaker trip: usually crash-looping
flared pods (OOM, bad storage) or node pressure. Check pod restart counts
and events; fix the underlying cause. Churn is safe for data (promotion
only ever selects live, data-bearing replicas) but each cycle costs
reconstruction bandwidth.

## Backup / Restore

See docs/BACKUP_RESTORE.md for the full procedures (tier-1 checkpoints,
S3 tier-2, single-partition vs multi-partition restore and its caveats).
Monitoring: alert when `time() - rocksdb_last_backup_epoch` exceeds twice
the backup interval (exposed via flared `stats`; needs a memcached
exporter).

## Scaling

- Scale OUT (more partitions/replicas): edit the FlareCluster spec;
  covered by the scale-out e2e suites. One reconstruction per partition at
  a time (proxy-pool throttling) is expected — patience, not a bug.
- Scale IN partitions is BLOCKED by the operator on purpose (data loss
  risk). Plan a migration instead.
- Blue/green cluster migration: `spec.clusterReplication` — validate on
  staging first; see the failover-during-replication e2e for the tested
  failure mode.

## Known limits (do not be surprised by)

- Selective network partition (pod alive, TCP to operator blocked) is
  mitigated (per-tick rebroadcast, lease fence) but not fully modeled —
  a wedged-but-probe-passing flared is not failed over automatically.
- Multi-partition restore requires manual partition-affinity verification
  (BACKUP_RESTORE.md Case C) until partition pinning is implemented.
- Config changes: hot-reloadable options land within ~2min (kubelet
  propagation + verified re-SIGHUP); WAL-retention/cache options need a pod
  restart — the operator logs which is which.
