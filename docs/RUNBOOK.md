# Flare Operator Runbook

## Upgrading a release (READ THIS FIRST)

Helm treats the chart's `crds/` directory as **install-only**: `helm
upgrade` never touches CRDs. If a release adds CRD schema fields (the
rocksdb block, circuitBreaker, …), an upgraded cluster silently rejects
or PRUNES patches to those fields — `kubectl patch` appears to succeed
while the field vanishes (observed live: circuitBreaker settings were
dropped on a cluster whose CRD predated the schema).

Upgrade procedure, always:

```bash
kubectl apply -f helm/flare-operator/crds/flarecluster.yaml   # CRDs first
helm upgrade flare ./helm/flare-operator -n flare-system --reuse-values \
  --set image.tag=<version> --set cluster.image.tag=<version>
```

Verify the schema took: `kubectl patch flarecluster <name> --dry-run=server
--type=merge -p '{"spec":{"circuitBreaker":{"tripThresholdPercent":50}}}'`
must NOT warn about unknown fields.

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

## Replacing a node with corrupt data {#replace-corrupt}

To service out a node whose local data looks corrupt and rebuild it from a
healthy peer.

**CRITICAL — wipe the local data first.** `kubectl delete pod` alone keeps
the PVC, so the corrupt RocksDB comes back. Worse, WAL-first reconstruction
sees the intact `__flare_repl_last_lsn`/`__flare_repl_master_id` and applies
only the delta *on top of the corruption* — it does not repair it. You must
empty the node so it falls back to a full dump from a healthy master
(`last_lsn=0` → WAL path skipped → full dump with the gated truncate). While
rebuilding, the node is Prepare / balance 0 and serves no reads, so the
corrupt copy is never exposed.

**Case A — a SLAVE is corrupt** (its partition still has a healthy master):

```bash
CTX="--context <ctx>"; NS=flare-system
kubectl $CTX -n $NS exec default-nodes-<N> -- sh -c 'rm -rf /data/flare/flare.rocksdb'
kubectl $CTX -n $NS delete pod default-nodes-<N>       # restarts empty → full dump from master
```
Wait for the operator to report `P=0` again. (To recycle the whole volume
instead: `delete pod` → `delete pvc data-default-nodes-<N>` → `delete pod`;
the StatefulSet recreates an empty PVC and pod.)

**Case B — a MASTER is corrupt.** Promote a healthy slave FIRST, or the
other slaves rebuild from the corrupt master and the corruption spreads:

```bash
# 1) confirm the partition has a healthy Active slave (stats nodes / node sync)
# 2) graceful delete → operator promotes a live, data-bearing slave (zombie guard)
kubectl $CTX -n $NS delete pod default-nodes-<masterN>
# 3) once the old master rejoins as a slave, wipe + restart it (as Case A)
kubectl $CTX -n $NS exec default-nodes-<masterN> -- sh -c 'rm -rf /data/flare/flare.rocksdb'
kubectl $CTX -n $NS delete pod default-nodes-<masterN>
```

**Case C — every copy of a partition is corrupt.** There is no healthy peer
to rebuild from; restore from a checkpoint (see Backup / Restore below).

Safety: the full dump only ever pulls from a healthy master, and the #14
truncate gate refuses to truncate toward an empty/not-newer source, so a
wipe-and-rebuild cannot cascade emptiness; promotion always picks a
data-bearing Active slave.

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
  risk). Reducing partitions in place orphans every key that hashes to a
  removed partition. To reduce partitions (= reduce the number of
  masters), do a shrink migration — see below.
- Blue/green cluster migration: `spec.clusterReplication` — validate on
  staging first; see the failover-during-replication e2e for the tested
  failure mode.

## Reducing masters / partitions (shrink migration) {#shrink}

There is no in-place partition reduction (the operator refuses it). To go
from N masters to M (M < N), migrate to a new, smaller cluster with
`spec.clusterReplication` and cut over. Because one operator manages
exactly one FlareCluster (namespace + clusterName), v1 and v2 are two
separate helm releases; keys are re-hashed into v2's partition count by
v2's own index, so v1(4 partitions) → v2(2) is fine.

1. **Stand up v2** (the target size) in its own namespace/clusterName:
   `helm install flare-v2 ./helm/flare-operator -n flare-v2 --create-namespace
   --set namespace=flare-v2 --set clusterName=<v2> --set cluster.enabled=true
   --set cluster.partitions=<M> --set cluster.replicas=<R>`. Wait for it to
   converge (`nodes=… M=<M> … P=0`).
2. **Start replication** on v1: patch its FlareCluster
   `spec.clusterReplication` to `{enabled:true, serverName:<v2 nodes svc
   FQDN>, port:12121, mode:"duplicate", concurrency:2}`. The operator drives
   None→**Dumping** (bulk-copies v1's existing data to v2, re-hashed into M
   partitions) then →**Forwarding** (v1 also mirrors live writes to v2).
   Watch `status.migrationPhase`.
3. **Verify data landed on v2** before cutover: sample keys on v2 and check
   counts. This is the least-proven step — the cluster-replication e2e now
   asserts a 2→1 shrink keeps every key, but VERIFY on your real data set.
4. **Cut over** application traffic to v2's endpoint.
5. **Stop + delete v1**: set `spec.clusterReplication.enabled=false` (the
   operator strips the replication config and SIGHUPs, so v1 stops
   forwarding — see the disable path), confirm v1 is idle, then
   `helm uninstall flare -n <v1 ns>`.

Rollback before step 4 is trivial (traffic never moved); after step 4,
treat v1 as the stale copy — writes since cutover exist only on v2.

CAUTION: cluster replication is the least-hardened path in this operator
(several bugs were found and fixed here). Rehearse the whole sequence on
staging with a representative data set and confirm per-key survival on v2
before doing it in production.

## Known limits (do not be surprised by)

- Selective network partition (pod alive, TCP to operator blocked) is
  mitigated (per-tick rebroadcast, lease fence) but not fully modeled —
  a wedged-but-probe-passing flared is not failed over automatically.
- Multi-partition restore requires manual partition-affinity verification
  (BACKUP_RESTORE.md Case C) until partition pinning is implemented.
- Config changes: hot-reloadable options land within ~2min (kubelet
  propagation + verified re-SIGHUP); WAL-retention/cache options need a pod
  restart — the operator logs which is which.
