# Flare Operator Runbook

## Upgrading a release (READ THIS FIRST)

The CRDs live in `templates/crds.yaml`, gated by `crds.install` — **not** in
Helm's install-only `crds/` dir. So whoever owns them (`crds.install=true`)
carries schema changes on `helm upgrade`; the old trap where `helm upgrade`
silently skipped CRDs (and patches to new fields like rocksdb/circuitBreaker
were PRUNED) is gone. Which release owns the CRDs depends on the layout:

- **Standalone / single cluster** (`crds.install=true`, the default): `helm
  upgrade` applies CRD schema changes in-band. Nothing extra to do.
- **Multi-cluster / multi-operator**: a dedicated `flare-crds` release owns the
  CRDs and every instance runs `crds.install=false`. **Upgrade `flare-crds`
  FIRST, then the instances** — an instance upgrade cannot carry a schema
  change. See [Multi-cluster CRD ownership](#multi-cluster-crd-ownership).

Standalone upgrade:

```bash
helm upgrade flare ./helm/flare-operator -n flare-system --reuse-values \
  --set image.tag=<version> --set cluster.image.tag=<version>
# CRDs upgrade in-band because crds.install defaults to true.
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

## FlareNodeUnhealthy (critical) {#node-unhealthy}

A node's POD IS PRESENT but it stopped being Ready long enough that the
operator treated it as dead and failed over. This is NOT a rescheduling
event — the pod is there, so the flared PROCESS is broken: segfault (the
container restarts under the same pod name and IP), a hang, or a wedge.
Before this detection existed the operator's only liveness signal was pod
existence, so such a node stayed Active indefinitely: the master kept
proxying writes into a dead socket and a crashed MASTER got no failover.

1. Which node, and did the container restart?
   `kubectl -n <ns> get pods -o wide` — a non-zero RESTARTS with
   `lastState.terminated.exitCode` 139 (SIGSEGV) or 137 (OOMKill) tells you
   which. Read that pod's previous logs: `kubectl logs <pod> -c flared
   --previous`.
2. Confirm the failover landed: `node sync` shows an Active master for the
   partition, and the promoted node is the data-bearing one.
3. Recovery is automatic — the container restarts (kubelet liveness is a
   tcpSocket probe, ~30s), flared re-registers, goes Prepare, catches up via
   WAL, and returns Active. If it does not, see
   [node-down-stuck](#node-down-stuck).
4. **Check for divergence caused by the outage**: while the node was dead the
   master dropped the writes it could not forward. Look at
   `flare_node_proxy_write_dropped` on the master over the incident window
   (see [proxy-write-dropped](#proxy-write-dropped)).
5. If the exit code was 139, capture the log line before the crash and file
   it — flared should not segfault.

## FlareNodeDownStuck (warning) {#node-down-stuck}

A node sits Down while its pod is alive. Down does not clear itself: the
operator only re-seats a node that RE-REGISTERS, and while the committed map
says Down the readiness probe keeps failing (it asks flared for its own
Active state), so only a fresh flared process breaks the loop.

The operator restarts such a pod itself after ~5 min
(`FLARE_DOWN_RESTART_CYCLES`), but only when **every partition already has an
Active master** and the circuit breaker is not tripped — deleting a pod on a
tmpfs cluster erases that node's copy, so the gate exists to never destroy
the last one. This alert firing for 15 min means the gate is holding.

1. Why is the gate closed? `node sync` — is a partition masterless
   ([master-missing](#master-missing)), or is the breaker tripped
   ([circuit-breaker](#circuit-breaker))? Fix that first; the restart then
   happens on its own.
2. If you must act manually, confirm another node holds the partition's data
   (`printf 'stats\r\n' | nc <pod-ip> 12121`, compare `curr_items`) BEFORE
   deleting the Down pod.
3. Never delete both replicas of a partition on a tmpfs cluster.

## FlareProxyWriteDropped (critical) {#proxy-write-dropped}

A master GAVE UP forwarding writes to a replica: `queue_proxy_write`
exhausted its retries and dropped the op. The client was already told the
write succeeded (the master's own write did succeed), so **that replica now
silently diverges until it reconstructs**. Live replication is op-level
proxying with no per-write acknowledgement, so this counter is the only
signal — see docs/STPA-node-state.md (gap G1).

1. Scope it: `increase(flare_node_proxy_write_dropped[1h])` per pod, and
   correlate with the replica's health over the same window (a
   [node-unhealthy](#node-unhealthy) event, a pod restart, or a network
   incident).
2. The divergence does not repair itself. To force a clean copy, make the
   replica reconstruct: delete the REPLICA's pod (never the master's), then
   watch it go Prepare → Active. On a PVC cluster the WAL path makes this
   incremental; on tmpfs it is a full reseed.
3. Verify convergence: `curr_items` on master and replica should agree
   (allow a small lag for in-flight writes).
4. If drops recur without a node incident, suspect the network path
   (cross-AZ / peering) and check the master's flared log for the
   `proxy write DROPPED` lines — they name the destination and the key.

## FlareDrainNoSuccessor (critical) {#drain-no-successor}

A Terminating (draining) master has NO promotable slave. The operator keeps
it as master so it serves until the very end of its grace period (demoting
early would only make the partition masterless sooner), but **when the pod
dies the partition loses its only data-bearing node and no automation can
prevent it** — pod deletion cannot be cancelled (deletionTimestamp is
irreversible). Typical trigger: deleting/evicting a partition's master and
slave together (manual both-pod delete, node drain with co-located replicas,
`rollout restart` of a 1p×2r StatefulSet).

You have roughly the preStop window (`cluster.drainSeconds`, default 60s):

1. **Trigger a final backup NOW** so the reseed rewinds minutes, not an hour:
   `printf 'backup\r\n' | nc <master-pod-ip> 12121` (the backup CronJob's
   runner does the S3 upload of the freshest checkpoint on its next run; if
   time allows, fire the CronJob manually:
   `kubectl create job --from=cronjob/<cluster>-backup drain-final -n <ns>`).
2. If a slave is mid-reconstruction (Prepare), it may still reach Active in
   time — watch `node sync`; promotion happens automatically if it does.

What happens after the pod dies:
- **PVC cluster**: the same-name pod returns with its data; `lastMasterOf`
  re-promotes it. Recovery is automatic, the alert clears itself.
- **tmpfs cluster**: the pod returns EMPTY; backupBootstrap reseeds from the
  newest S3 backup (up to `backupBootstrap.maxAgeSeconds` old) and everything
  written since that backup is LOST. The final backup from step 1 is what
  bounds the loss.

The end-state (masterless partition) also fires
[FlareMasterMissing](#master-missing); this alert is the EARLY warning while
the doomed master is still alive and a final backup is still possible.

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
  failure mode. For seeding a NEW cluster from another flare, follow
  [Seeding via cluster replication](#replication-seeding) — in particular
  its backup ordering.

## Seeding a new cluster via cluster replication {#replication-seeding}

Standing up a cluster whose data comes from another flare (classic or
operator-managed) over `cluster-replication`. The one rule that is easy to
get wrong: **backups stay OFF until the replication catch-up plateaus, then
get enabled.** Three reasons (all observed live on pf-dev, 2026-08-20):

- During the transfer the SOURCE is authoritative. A backup of a
  half-filled target protects nothing — recovery from a mid-transfer loss
  is "redo the transfer from the source", never "restore the partial S3
  backup" (which would seed stale, incomplete data under a fresher
  bootstrap window).
- `duplicate` mode only forwards writes issued AFTER it was enabled: a
  target wiped mid-transfer cannot re-fill from the stream alone, so the
  partial backup gives false confidence.
- Backup checkpoints hardlink-pin the SST set of their creation moment.
  Under bulk-influx compaction churn, nearly the whole DB diverges within
  the hour (measured: 338MB of a 416MB checkpoint had become unique bytes
  1h after creation), so every hourly checkpoint costs ~a full extra DB
  copy — and on a tmpfs cluster that cost is RAM against the pod's memory
  limit.

Procedure:

1. Pause backups and bootstrap ROLL-FREE: set
   `cluster.backup.suspend: true` and `cluster.backupBootstrap.enabled:
   false`. Both are runtime toggles — suspend is a CronJob field and the
   bootstrap flag lives in the `<cluster>-flags` ConfigMap read at pod
   start — so the pod template does not change: **no rolling restart, no
   master handoff, the replication sender's target IP stays put**. Do NOT
   set `backup.enabled: false` for a pause (that deletes/recreates the
   CronJob object; suspend is strictly gentler), and never toggle anything
   that edits the pod template mid-seed (image tags, resources, labels —
   those ALWAYS roll pods; K8s pods are immutable).
2. If the source holds PRE-EXISTING data, run an initial bulk transfer
   (snapshot-push / dump); the duplicate stream alone only carries new
   writes.
3. Enable replication on the source pointing at the TARGET MASTER directly —
   not the client LB. Each partition has a master-pinned headless Service
   `<cluster>-<partition>` whose Endpoints the operator re-points at the
   current master within a reconcile tick; look up the address:
   ```bash
   kubectl -n <ns> get endpoints <cluster>-0 \
     -o jsonpath='{.subsets[*].addresses[*].ip}'
   ```
   Pod IPs are VPC-routable (TKE VPC-CNI), so a peered source reaches them
   without the LB — no LB idle-timeout mid-stream, no slave-proxy detour,
   and an ADDRESS CHANGE MEANS THE MASTER MOVED (re-point the source and
   restart its stream; the client LB VIP is unaffected either way). Then
   verify arrival: target master `curr_items` rising, slave tracking a few
   hundred keys behind.
4. Wait for catch-up: target `curr_items` ≈ source, lag stable. During this
   window the WAL archive grows to its cap (`walSizeLimitMb`) — that is
   sizing, not a leak.
5. Resume roll-free: `backup.suspend: false` + `backupBootstrap.enabled:
   true` → sync (ConfigMap + CronJob field only; pods untouched). A stale
   pre-transfer checkpoint under `/data/flare/backups/` is pruned by the
   next run (prune-before-create); `rm -rf` it to free the RAM immediately.
   Note the flags ConfigMap propagates to pods within ~1 min, and the init
   only consults it at pod start anyway — bootstrap coverage begins with
   the next pod (re)creation, which is exactly when it matters.
6. Verify the safety net is live: backup Job `Complete` AND a fresh object
   in the bucket (`latest/p0/CURRENT` LastModified). Only from this point
   is `backupBootstrap` a real whole-cluster-loss net; before it, the
   recovery path is step 2/3 again.

## Multi-cluster CRD ownership {#multi-cluster-crd-ownership}

Running many flare instances (multiple operators, one or many namespaces) on a
single K8s cluster — the 20-30-instance target. **The `FlareCluster` /
`FlareMigration` CRDs are cluster-scoped and SHARED by every instance.** They
are one object per K8s cluster; you cannot give each instance its own copy
without minting a new API group per instance (30 near-identical CRD types —
rejected: `kubectl get fc -A` stops working, schemas drift, no single source of
truth). So the rule is: **one shared CRD, owned by nobody's instance.**

Layout:

- **One dedicated `flare-crds` release** owns the CRDs. It renders CRDs and
  nothing else:
  ```bash
  helm install flare-crds ./helm/flare-operator -n flare-system \
    --set operator.enabled=false --set cluster.enabled=false --set crds.install=true
  ```
  (In GitOps: one Application pointing at the chart with those values. Give it a
  sync-wave earlier than the instances so CRDs exist first.)
- **Every instance release sets `crds.install=false`** and consumes the shared
  CRDs. An instance never ships or owns a CRD:
  ```bash
  helm install flare-<name> ./helm/flare-operator -n <ns> \
    --set crds.install=false --set clusterName=flare-<name> ...
  ```

Why this split (do not undo it):

- **Deleting an instance is safe.** No instance owns the CRDs, so removing one
  (or its whole namespace) cannot cascade-delete another instance's CRs. Belt
  and braces: the CRDs also carry `helm.sh/resource-policy: keep` +
  `argocd.argoproj.io/sync-options: Prune=false`, so even an accidental owner
  teardown won't prune them.
- **Adding instance #21..#30 is trivial** — `crds.install=false`, new
  `clusterName`, done. No CRD coordination.

### Schema changes across many instances

- **Additive change (new optional field — the normal case):** bump and upgrade
  the **`flare-crds` release FIRST**, then roll the instances at their own pace.
  Old-version operators ignore the new field; new-version operators require the
  CRD to already know it (the schema is strict — unknown fields are pruned), so
  CRD-first ordering is mandatory. All prior changes (rocksdb, circuitBreaker,
  readBalance, standby) were additive and safe this way.
- **Breaking change (rename/retype/remove):** do NOT split the CRD per instance
  to dodge it. Add a **new served API version** (`v1alpha1` → `v1beta1`) to the
  shared CRD, serve BOTH during the transition, migrate instances onto the new
  version as they upgrade, then drop the old served version once no CR uses it.
  This is the "change the prefix/version only when you actually break" strategy —
  it isolates the break without the 30-CRD sprawl. A conversion webhook is only
  needed if old and new must be read interchangeably mid-flight; for a rolling
  per-instance cutover, served-both-then-retire is enough.

### Retiring flare from the whole K8s cluster

The guards stop automatic deletion, so removal is deliberate:

```bash
# after every instance + the flare-crds release are gone:
kubectl delete crd flareclusters.flare.gree.net flaremigrations.flare.gree.net
```

Only run this when retiring flare from the entire cluster — it removes the type
and every remaining CR cluster-wide.

## Reducing masters / partitions (shrink migration) {#shrink}

**PREFERRED (rc31+): drive the whole sequence with a `FlareMigration` CR** —
the manual choreography below still works but the CR automates it with
proven gates. Same namespace, one release:

```yaml
apiVersion: flare.gree.net/v1alpha1
kind: FlareMigration
metadata: {name: shrink-1p, namespace: <ns>}
spec:
  source: <current clusterName>
  target: {name: <new name>, partitions: M, replicas: R}
  externalService: <client-facing Service to flip at cutover>
```

Phases (watch `kubectl get fmig`): Provisioning → Duplicating (with equal
partition counts the initial transfer is a physical snapshot push; rc33) →
Forwarding → **AwaitingCutover** (park; set `spec.approveCutover: true`) →
CutOver (Service selector flip, same LB/IP) → **AwaitingRetire** (park; set
`spec.approveRetire: true`) → Retired (source STS+CR deleted, PVCs kept).
`spec.paused: true` freezes any phase; `spec.abort: true` rolls back
(refused after cutover). All gates are machine-checked (Migration/Types.lean).

**Post-migration handoff (rc35+, mostly automatic):** target resources are
born with helm adoption metadata, so the ONE manual step is the GitOps
values switch — set `clusterName`/`cluster.name` to the target (+ its
partitions/replicas) and `helm upgrade`. The moment the release's operator
pods restart with the new `--cluster-name`, the migration-provisioned
`<target>-operator` detects the Ready successor and DELETES ITSELF,
releasing `<target>-operator-lease` immediately. Do NOT delete it by hand
before the upgrade, and do not skip the values switch: a release whose
values still name the retired source will recreate it on the next upgrade.

---

The manual procedure (two releases, cross-namespace) remains valid:

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
2. **Start the bulk copy** on v1: patch its FlareCluster
   `spec.clusterReplication` to `{enabled:true, serverName:<v2 nodes svc
   FQDN>, port:12121, mode:"duplicate", concurrency:2}`. The operator applies
   `mode=duplicate` → **Dumping**: v1's masters bulk-copy existing data to v2
   (re-hashed into M partitions) AND mirror live writes. The transition is
   **declarative and user-driven** — the operator does NOT auto-advance to
   forward. Watch `status.migrationPhase` (also exported as
   `flare_operator_migration_phase` → Grafana Cloud).
3. **Verify data landed on v2** before advancing: sample keys / compare counts
   on v2 (watch v2's `flare_node_curr_items` rise in Grafana Cloud). The
   cluster-replication e2e asserts a 2→1 shrink migrates every key via the
   duplicate dump, but VERIFY on your real data set.
4. **Advance to forward (your call)**: once v2 is caught up, patch
   `spec.clusterReplication.mode: "forward"` → **Forwarding** (v1 mirrors only
   live writes; the initial dump is done). Optional — you can also stay in
   duplicate through cutover; forward just avoids re-dumping.
5. **Cut over** application traffic to v2's endpoint.
6. **Stop + delete v1** (or CANCEL at any point): set
   `spec.clusterReplication.enabled=false` — the operator strips the config and
   SIGHUPs, so v1 stops forwarding (phase→None). Before cutover this is a clean
   rollback (traffic never moved). Then confirm v1 idle and
   `helm uninstall flare -n <v1 ns>`.

SAFETY — master change during migration: if a v1 partition's master
fails over/promotes mid-migration, the operator **aborts** the migration
(strips config, phase→None, bumps `flare_operator_migration_aborted_total`)
rather than shipping an inconsistent copy — source-cluster failover is never
blocked. Because the spec still says `enabled=true`, the migration
auto-restarts (fresh dump) once the cluster reconverges; to stop for good,
set `enabled=false`. (The operator only sees v1's masters; keep v2 stable
during the migration.)

Rollback before cutover is trivial (traffic never moved); after cutover,
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
