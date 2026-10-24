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

**Argo CD with server-side diff: a new chart DEFAULT on the CR breaks the
sync.** Argo CD dry-runs the new FlareCluster against the CRD that is
installed now, before it applies anything. When the new chart both adds a
field to the CRD and fills it by default (rc64: `spec.rocksdb.maxTotalThreadQueue:
200000`), the dry run against the old CRD fails with `field not declared in
schema`, the app is stuck in a comparison error, and the CRD never gets
installed. Roll in two steps: first the new version with the field removed
from the CR (a kustomize JSON patch `op: remove`; a values `null` is not
enough, the chart renders `spec.rocksdb` with `toYaml` and keeps the key),
then drop the patch once the new CRD is in. Check the PR's diff report for
the instance before merging (pf-dev PR moc2-k8s#9362).

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

## FlareMasterRefusesToServe (critical) {#master-refuses}

Meaning: the node map makes this pod a master, but flared refuses to act as
one (`stats`: `promotion_refused 1`; flared log `PROMOTION REFUSED by this
node: <reason>`). Reads and writes for its partition fail. `FlareMasterMissing`
does NOT fire (the map has a master). The value is read from the node itself;
an unreachable node is not reported here (see `up` / FlareNodeUnhealthy).

Reasons (in the log): the copy is being rebuilt / parked / part-way /
quarantined / its identity records disagree, or a RESTORED copy of another
partition / without a partition binding (RUNBOOK#restore-refused).

Do: read the reason. A transient one (a rebuild finishing) clears when the
node is re-mapped; a restored copy of the wrong partition needs the right
backup. Nothing is promoted or removed automatically because of this alert.

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
3b. **If the log says the master was KEPT** ("has NO promotable successor —
   kept as master"), the partition has no replica to promote, so the
   operator deliberately did not demote it: demoting would only make the
   partition masterless sooner and break the returning process's clean
   rejoin. Note `FlareMasterMissing` will NOT fire here (the map still shows
   a master) — this alert is the signal. The partition serves nothing until
   that process comes back; if it will not, restore from backup
   (docs/BACKUP_RESTORE.md). Standing fix: run the partition with a replica.
4. **Check for divergence caused by the outage**: while the node was dead the
   master dropped the writes it could not forward. Look at
   `flare_node_proxy_write_dropped` on the master over the incident window
   (see [proxy-write-dropped](#proxy-write-dropped)).
5. If the exit code was 139, capture the log line before the crash and file
   it — flared should not segfault.

## FlareNodeUnreachableFromOperator (critical) {#node-unreachable}

The operator cannot open a TCP connection to a node that K8s still reports
Ready. Almost certainly the node is serving clients normally — what is
broken is the **operator→pod path**, so topology pushes are not landing and
that node keeps running on whatever map it last received. Wrong roles
(a demoted node still believing it is master, a promoted one not knowing it
is) persist until the path heals.

Nothing else sees this: the readiness probe runs inside the pod (kubelet
asking flared about itself) and the operator's stats probes travel through
the API server, so both stay green.

**The operator deliberately does NOT fail the node over.** Unreachability is
a loss of the operator's own feedback and the fault may be on the operator's
side; demoting a master we merely cannot see would be the damaging move.

1. Establish which side is broken. From the operator pod:
   `kubectl -n <ns> exec deploy/<cluster>-flare-operator -- sh -c 'timeout 3
   bash -c "</dev/tcp/<pod-ip>/12121" && echo ok'`. Then try the same from a
   different pod in the namespace. If only the operator fails, suspect its
   node's networking or a NetworkPolicy.
2. Check whether the node is actually serving: `printf 'stats\r\n' | nc
   <pod-ip> 12121` from a debug pod, and look at its request rate.
3. Compare what that node believes with what the operator committed:
   `printf 'stats nodes\r\n' | nc <pod-ip> 12121` versus
   `kubectl -n <ns> get cm <cluster>-node-map -o jsonpath='{.data.nodeMap}'`.
   A mismatch confirms it is running on a stale map.
4. Fix the path (CNI, NetworkPolicy, node networking). Once reachable, the
   next topology change is pushed automatically; force one sooner by
   restarting the operator, which re-broadcasts on its first tick.
5. If the path cannot be fixed quickly and the node's role is wrong in a way
   that matters (it believes it is master for a partition someone else now
   masters), delete that pod — it re-registers with a clean view.

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

## FlareResyncFailing (critical) {#resync-failing}

A node's reconstruction keeps failing and it has passed
`rocksdb-resync-failure-threshold` consecutive failures.

flared *would* take itself out of service here, and for years its log said
it had — but that path (`request_down_node`) enqueues to a controller thread
only the standalone index process runs. Under this operator it fails
silently, so **nothing takes the node out of service**. It keeps its role
and, if it is a master, keeps serving whatever data it has. The log now says
so plainly; this alert is the signal.

1. Read the node's flared log for why the resync fails: WAL purged
   (`rocksdb_wal_sync_lsn_purged`), master_id mismatch, CRC mismatch, or a
   connection error to its source. Each points somewhere different.
2. Decide whether it is serving. `printf 'stats nodes\r\n' | nc <pod-ip>
   12121` for its role, and `curr_items` versus its peers.
3. Take it out yourself if it is a replica: delete that pod so it
   reconstructs from scratch. If it is a master with a healthy replica,
   deleting it hands over through the drain path.
4. If a master has NO replica, do not delete it — that is the last copy.
   Trigger a backup first (docs/BACKUP_RESTORE.md), then decide.

## FlareReplicaDivergence (warning) {#replica-divergence}

A replica's key count has differed from its master's by more than 0.5% for
half an hour. Live replication is op-level proxying with no per-write
acknowledgement, so a write the master could not forward is simply gone from
that replica until it reconstructs — this gauge is the only routine
comparison of the two copies.

It is a coarse signal on purpose: equal counts do not prove equal content,
and a small transient gap is normal (writes in flight, expiry timing). A gap
that persists for 30 minutes is not.

1. Get the real numbers: `printf 'stats\r\n' | nc <pod-ip> 12121` on the
   master and on each replica; compare `curr_items`.
2. Establish the direction. A replica with MORE keys is usually expired
   residue (pre-rc58 the expire reaper deleted only on the master); a
   replica with FEWER keys means it missed writes — check
   `flare_node_proxy_write_dropped` on the master
   ([proxy-write-dropped](#proxy-write-dropped)) and whether that replica had
   a [node-unhealthy](#node-unhealthy) episode.
3. Sample the content before assuming: pick keys via `dump_key <partition>
   <partition_size>` (use the cluster's REAL partition count — a wrong
   partition_size crashed a node pre-rc57) and `gets` the same keys on both
   sides, comparing value size and CAS.
4. Repair by making the replica reconstruct: delete the REPLICA's pod, never
   the master's. On a PVC cluster the WAL path makes it incremental; on tmpfs
   it is a full reseed. Verify the counts converge afterwards.

## FlareReplicaFollowLag / FlareReplicaNotFollowing (warning) {#replica-follow}

Per-replica signals from the replica's own `/metrics`:

- `flare_node_repl_follow_lag`: the source position minus the applied position.
- `flare_node_repl_follow_info{state,source,epoch}`: the follower's state and
  the source it is following.

`flare_operator_node_role{pod,partition,role,state}` says which pod the
operator has as master and slave.

1. **Lag above 1000 for 5 min.** The replica is withheld from reads, so
   clients go to the master. Check write rate against follow throughput, and
   check the network between the replica and its master. The sustained
   evaluation measured lag 0 at 900 writes/s, and a deficit at 2000 writes/s
   on kind with flared at 500m CPU (lag 0 at 2000 writes/s with 2 cores), so
   check the replica's CPU throttling first. A lag that keeps growing means the follower cannot keep up. Find
   the cause before the master's WAL cap purges the history, which turns this
   into a rebuild (`needs_rebuild`, reason `lsn_purged`).
2. **Not following for 15 min.** Read `state` and `repl_follow_last_reason`
   in the replica's `stats`.
   - `disconnected`: the replica cannot reach its source.
   - `needs_rebuild`: the operator should already be rebuilding it; see
     FlareResyncFailing if it is not.
   - `initial_sync` for a long time: a large initial copy. Compare against
     the expected copy time for the data size.
3. Do not delete the pod as a first step. On tmpfs that deletes its data. On
   PVC it forces a reconstruction that following would have avoided.

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

## Partition held for its ex-master (failover lag bound) {#failover-lag-hold}

Log line: `CRITICAL: partition N has NO master: its only data-bearing copy
[...] is unfit ... waiting for the ex-master to return`. Also fires
[FlareMasterMissing](#master-missing).

The master died while its follower was further behind than
`FLARE_FOLLOW_FAILOVER_MAX_LAG` (operator env, default 100000 positions), or
had declared its copy unusable. Promoting it would discard everything it
never received, so the operator leaves the partition WITHOUT a master and
waits for the ex-master. Writes to the partition fail meanwhile.

- **PVC cluster**: the same-name pod returns with its data and is master
  again; the follower then rebuilds or catches up from it. Nothing to do
  unless the pod cannot come back (node lost, PVC stuck): fix that first.
- **tmpfs cluster**: the ex-master returns empty, so there is nothing to
  wait for and the follower is seated at once (logged `PROMOTION NOT
  LOSS-FREE ... LAST RESORT`).
- **The wait is bounded**: after `FLARE_FOLLOW_FAILOVER_WAIT_SECONDS` (default
  300, counted from the first pass that sees the partition masterless, so
  about one minute more in all: 117 s for a 60 s wait on CI) the
  follower is seated anyway with the same NOT LOSS-FREE line. A write it
  never received is not in its copy; whether any exists is NOT measured. Set the variable to 0 to never wait (the behaviour
  before 2026-10-03); raise it where losing writes is worse than a longer
  write outage.

To shorten the outage by hand, accepting the loss, set the variable lower
and restart the operator.

**Write authority ON: a returning copy that is not yet in the membership
record (2026-10-24).** When the only record member cannot be promoted (it
was demoted by replica repair, or its history is unknown) and the sole
data-bearing copy is a same-history lagging copy that is not a member of
the record, the operator promotes it by fencing the old master with the
member's expired promise. Log: `PROMOTION NOT LOSS-FREE (write authority): ...
the old master is fenced by member ...`. Same loss caveat as above (a write
only the old master acknowledged is not in the copy). A copy with another
history, a rejoining one, or one when a record member can be promoted is
still refused (`abort: the candidate is not in the membership`).

**A dead ex-slave that comes back (decision 2026-10-16).** A slave that
died while Active keeps its partition in the persisted node map
(`slaveOf=P` on its line in `<cluster>-node-map`). When it re-registers it
rejoins that partition as Slave/Prepare — never by its name, and never a
copy that was repair-held, drained or mid-reconstruction (those carry no
`slaveOf`). It can be seated only by the masterless refill under the rule
above, and only after its own report proves its copy: every copy-integrity
key reported healthy (`rocksdb_copy_partial 0`, `rebuild_in_flight 0`,
`rebuild_parked 0`, `rocksdb_switch_unresolved 0`,
`rocksdb_copy_identity_consistent 1`, `rocksdb_quarantined 0`, a copy id),
not empty, `rocksdb_partition_binding` exactly the partition's, the
partition's RECORDED history, no failed / aborted reconstruction. Missing
proof = `unknown (attributed rejoin: ...)`, held; a forbidden marker or
another history = FORBIDDEN, never seated, not even after the wait. An
ex-master read empty ends the wait only when every other copy of the
partition was observed (read with data or read empty); a copy that is Down
or unread keeps it until the wait expires.

While a partition has no master the operator logs, on change and at most
once a minute, `CRITICAL: partition P has NO master
(flare_operator_partitions_masterless): copies: ...` with what was seen of
each copy and its class, also when there is no copy or every copy is
forbidden (FlareMasterMissing fires from the same gauge).

## Operator will not start: node map missing, invalid or unreadable {#node-map-lost}

At startup the operator reads `<cluster>-node-map` (ConfigMap) and decides
(SAF-09):

| Log line | Meaning | The operator |
|---|---|---|
| `loaded N nodes from ConfigMap` | normal | runs |
| `node map: starting fresh — first build: ... proven new` | no map; the Lease was read without a marker AND every expected flared pod reports node map 0 and 0 items | runs |
| `node map: starting fresh — first build APPROVED by annotation` | no map, the past could not be observed, and this FlareCluster carries a first-build approval | runs, then consumes the approval |
| `node map: retrying ... cannot be told from a loss` | no map, and the past could not be observed (Lease unreadable, a pod unreadable or missing a field, fewer pods than the spec) | retries 12 × 5 s, then exits 2; never starts fresh |
| `node map: retrying in 5 s ... reading the node map failed` | API error, timeout or forbidden | retries 12 × 5 s, then exits 2 (the pod restarts) |
| `CRITICAL: the node map is missing but the cluster ran before` | the map is gone while the Lease marker or a flared pod shows history | exits 3, stays down |
| `CRITICAL: the persisted node map is invalid` | content does not parse strictly | exits 3, stays down |

While the operator is down, **flared keeps serving with its last topology**.
Writes and reads continue. No failover happens and no topology changes are
applied.

1. **Failed read.** Fix API access or RBAC (`configmaps` get/update in the
   operator's ClusterRole). The operator then loads the map by itself.
2. **Missing or invalid map.** Restore the ConfigMap from a copy if you have
   one (key `nodeMap`, format `version=N` plus one line per node). The
   operator loads it on its next restart.
3. **No copy.** Set `FLARE_NODE_MAP_RESET=1` on the operator Deployment to
   accept a fresh start deliberately, then remove the variable. On a fresh
   start the operator rebuilds the map from the nodes' registrations: check
   every partition's master afterwards (`node sync`). A version gap with
   flared is handled by the leadership generation (SAF-09). The reset never
   overrides a failed read.

**First install, and approving a first build.** On a brand-new cluster
flared cannot answer stats until the operator serves, so the operator cannot
prove the cluster is new and waits in the "cannot be told from a loss" state.
Approve the first build of THIS FlareCluster, bound to its own UID:

```bash
kubectl annotate flarecluster <name> -n <ns> \
  flare.gree.net/first-build-approved=$(kubectl get flarecluster <name> -n <ns> -o jsonpath='{.metadata.uid}')
```

- The approval is one-shot. Once the first map is persisted, the operator
  removes the annotation and reads it back. If the annotation is still
  there, it logs CRITICAL and retries on every persist.
- A recreated FlareCluster has a new UID, so an old approval does not apply
  to it.
- An approval never overrides history the operator *can* see. If the map is
  missing while the Lease marker or a pod shows the cluster ran, the operator
  halts; only `FLARE_NODE_MAP_RESET=1` accepts a fresh start then.
- Blue/green migration approves the target cluster it provisions. The E2E
  setup approves each cluster it deploys.

Automatic reconstruction of a lost map from the nodes is not implemented yet.

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

### An in-place restore keeps the copy it replaces {#restore-in-place}

A restore into a pod that has a live copy does NOT remove it:

1. The hook (`flare-restore-hook`) checks provenance and **capacity**: the
   backup's size plus a reserve (`FLARE_RESTORE_RESERVE_BYTES`, default 64 MiB)
   must be free in the data dir. On tmpfs that is memory — room for two copies.
   Not enough = refused (`RESTORE.refused.reason`), the live copy is served.
2. It copies the backup next to the live copy (`restore-incoming-<ts>`, then
   `staging-restore-<ts>`) and names it in `RESTORE.switch`. An incomplete
   `restore-incoming-*` (a copy that failed) is left in place — remove it by
   hand once you have checked it.
3. flared, at start, switches it in with the copy switch: the live copy becomes
   `retained-restore-<ts>`. Log: `in-place restore ... RETAINED as ...`.
4. The retained copy is **never deleted automatically** (it has no switch
   record). Discard it only with a `FlareCopyDiscardApproval` after the
   restored copy is verified (master of its partition, data checked).

Stops (nothing moved or removed, CRITICAL in the log): `RESTORE.switch`
naming a copy that does not exist (renamed `RESTORE.switch.failed`, the live
copy is served); a live copy whose `COPY_ID` cannot be read (flared does not
start — move the live copy aside by hand, or remove `RESTORE.switch` to keep
it). A crash during the switch is resolved at the next start from what exists
on disk.

Open decisions (not implemented; fail-closed until decided): whether a
verified restore may ever delete its retained copy automatically; who may roll
an in-place restore back; old backups without a partition binding (refused).

### A restore refused for its provenance {#restore-refused}

Symptoms: the pod log has `flare-restore-hook: CRITICAL: RESTORE REFUSED: …`
and the data dir has `RESTORE.refused` + `RESTORE.refused.reason`; or flared
logs `PROMOTION REFUSED by this node: … RESTORED copy …` and `stats` shows
`promotion_refused 1`, `rocksdb_restored_unverified 1`.

Meaning: the backup is not the data of the partition / routing rule it was
put into (`rocksdb_partition_binding` names where it came from), or it was taken
before partition bindings existed and cannot be verified (after an upgrade:
take a backup with the new release first — a `backupBootstrap` from an older
backup is refused the same way). With a live copy the
hook kept it and flared serves it; without one the pod does not start (the
marker stays). Nothing was replaced.

Do: pick the backup of the right partition (`<cluster>/latest/p<N>/` keyed by
partition — check `flared --checkpoint-binding <dir>` on it), remove the
`RESTORE.refused*` files, and restore again. A backup without a binding is not
restorable on this release (take a new backup). Do NOT delete
`__flare_partition_binding` or edit the marker to force it: that is exactly the
mix-up the check prevents (keys of another partition served as this one's).
A master that refuses this way is not counted by
`flare_operator_partitions_masterless`; it raises FlareMasterRefusesToServe
(`flare_node_promotion_refused`) instead — writes to the partition fail
meanwhile.

## Enabling continuous replication on an existing cluster {#enable-follow}

Rehearsed by E2E `continuous-replication-enable` (a legacy cluster switched
on live through the CR, and back). Do one cluster at a time.

1. **Identity forwarding first, on every node:** set
   `spec.rocksdb.replIdentityForward: true`. The operator rewrites
   `extra.conf` and signals the pods. Check that every flared pod logged
   `repl_identity_forward: 0 -> 1` before going on.
2. **Then following:** also set `replFollowEnabled: true` (keep
   `replIdentityForward: true` in the same patch: the operator rewrites the
   whole file from `spec.rocksdb`). Each replica goes `idle` → `following`.
3. **Check:** `repl_follow_state` is `following` on every replica,
   `flare_node_repl_follow_lag` falls to about 0, and
   FlareReplicaNotFollowing stays quiet.

What the replica does on step 2: it fetches the master's WAL from its own
position, which dates from its last full copy (legacy forwards do not move
it). On kind the master still held that WAL, so the replica caught up with
no rebuild and the data stayed equal. On a long-running production cluster
that WAL will usually be purged already: the replica then declares
`needs_rebuild` (`lsn_purged`) and is rebuilt once (snapshot reseed;
E2E `continuous-replication-enable-purged` shows exactly this). Plan
for one rebuild per replica, with its reads withheld (clients go to the
master) until it follows. No stat shows the oldest WAL position the master
still holds, so this cannot be checked beforehand.

**Rollback**, reverse order: `replFollowEnabled: false` (wait for
`repl_follow_enabled: 1 -> 0` on every pod), then
`replIdentityForward: false`. Data stays as it is; nothing is rebuilt.

## Sizing flared memory and storage {#sizing}

These are floors, not bounds. The kind measurements bound nothing for
production hardware.

**Memory per flared pod.**

    floor = blockCacheSizeMb + 2 × writeBufferSizeMb × maxWriteBufferNumber

The 2 is the column families: default plus replication meta. The defaults
are 512 + 2 × 64 × 3 = 896 MiB. On top of the floor come compaction,
continuous-replication buffers, allocator fragmentation (`MALLOC_ARENA_MAX`
is set) and, **on tmpfs, the data itself**. A tmpfs emptyDir counts against
the pod's memory limit. The chart fails the render when the floor reaches
`cluster.resources.limits.memory`. It warns above 70% of the limit, when
floor + `tmpfs.sizeLimit` exceeds it, and when less than 256 MiB is left
above floor + tmpfs.

Measured RSS against the floor on kind (floor 448 MiB: block cache 64,
write buffers at their defaults):

| Run | RSS high-water | Above the floor |
|---|---|---|
| outage, 400 MB of 50 kB values, PVC (36741586970) | 620 MB | +172 MiB |
| outage on tmpfs (36914124394; tmpfs pages are not in RSS) | 543 MB | +95 MiB |
| 6M keys, forward queue capped (36985410132) | 457 MB (heap in use 182 MB, 259 MB freed but kept by the allocator) | +9 MiB |
| 2M keys, queue capped (36991784765) | 250 MB | below |
| 6M keys, queue NOT capped (36981303601) | 2.0 GB, then OOM | unbounded: keep `maxTotalThreadQueue` set |

Size the limit as **floor + tmpfs.sizeLimit + at least 256 MiB**. Below a
256 MiB margin the chart warns. Small-data E2E pods stay near 35 MB because
the floor is a ceiling the caches grow towards, not an up-front allocation.
The RSS above excludes tmpfs pages, which the cgroup still charges to the
pod. A 512Mi limit was OOM-killed in the scale evaluation.

**WAL archive (retention for followers).**

    archive budget ≈ walSizeLimitMb + bytes written between two cleanups

The cap is enforced when a flush or compaction runs cleanup, not by time. On
an idle master the archive stayed at 499 MB under a 256 MB cap for 22 min.
One flush cut it to 250 MB. Size the data volume for the budget above, not
for the cap. Outages within the retained WAL catch up from the cursor: 150 MB
took 11 s on kind. Longer outages lose the history (`lsn_purged`), and the
follower is rebuilt by snapshot: 59 s for about 1 GB on kind.

**Data volume.**

    volume ≥ live data × compaction headroom (about 2×) + archive budget

On tmpfs, keep `walSizeLimitMb` around 5% of `tmpfs.sizeLimit` and set a
short `walTtlSeconds` (see values.yaml).

**Follow throughput.** On kind, with flared at 500m CPU, lag stayed at 0 at
900 writes/s and grew at 2000 writes/s. With 2 cores it stayed at 0 at 2000
writes/s (run 37007519007). Give flared at least 2 cores where a partition
takes about 2000 writes/s. Leave `noreplyWindowLimit` unset: it gave no gain
(run 37007523321). Measure on production-like hardware against the real write
rate before relying on reads from followers.

**Forward queue.** Keep `maxTotalThreadQueue` set (chart default 200000,
about 600 B per queued forward, so about 120 MB). Without it, a master whose
follower falls behind buffers every pending forward until it is OOM-killed.
At the bound, forwards are dropped and counted in `proxy_write_dropped`, and
the follower repairs them from the WAL. That repair needs WAL retention, so
`walSizeLimitMb` must cover the backlog.

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
**held before the forward switch** (set `spec.approveForward: true` after
verification V — #migration-forward-gate) → Forwarding →
**AwaitingCutover** (park; set `spec.approveCutover: true`) →
CutOver (Service selector flip, same LB/IP) → **AwaitingRetire** (park; set
`spec.approveRetire: true`) → Retired (source STS+CR deleted, PVCs kept).
`spec.paused: true` freezes any phase; `spec.abort: true` rolls back
(refused once the forward switch was issued — #migration-forward-abort).
All gates are machine-checked (Migration/Types.lean).

### The forward switch is client-visible {#migration-forward-gate}

Forwarding is NOT a bookkeeping step: from it on the source flared runs in
forward mode — every client read and write that reaches the source is
proxied synchronously to the target and answered from it; the source's own
copy stops changing (cluster_replication.cc on_pre_proxy_read/write,
op_set/op_delete/op_incr). Until 2026-10-11 the operator switched as soon
as the target's summed `curr_items` ≥ the source's for 6 ticks — a key
COUNT, which equal counts with wrong values, missing deletes or a seed that
never ran also pass.

Now the switch needs ALL of, for THIS attempt (status.attemptBaseline is
read before duplication is enabled):
- key counts converged for 6 ticks, counted only while Duplicating;
- every source master: `cluster_replication_seed` completed_* and its
  `cluster_replication[seed_completed]` above the baseline, same process;
- loss over the WHOLE attempt (seed included): `proxy_write_dropped` and
  every `cluster_replication[forward_dropped_*|forward_failed_*|
  forward_missing_*|seed_failed]` unchanged since the baseline. A restart,
  a replaced pod, a counter that went down, an unreadable master, or a
  baseline read while replication was already on → **Unknown → held**
  (recreate the migration; nothing is inferred). `proxy_write_dropped`
  also counts in-cluster drops — a hold may be conservative;
- `spec.forwardApproval`: the line verification V prints for a MATCH only
  (docs/review-cross-cluster-2026-10-11.md §8, §9.1, `scripts/flare_verify_copy.py`):
  `v=1|verdict=MATCH|verified_at=..|attempt=<status.attemptId>|src=..|dst=..`.
  The operator re-reads every source and target partition master at the
  switch and refuses another attempt, any changed pod UID / start time /
  master id / copy id / epoch / sequence number, an unreadable master, or a
  verification older than 3600 s. `spec.approveForward: true` (a boolean)
  is NOT accepted any more — the message says so.

Procedure (ordered; every step a human act):
1. Stop client writes to the source (outside the operator; the operator
   cannot observe a fence — it only sees positions not moving).
2. Capture both sides and run V with `--attempt-id` = `status.attemptId`
   and the attempt baseline taken before the migration was created.
   Capture = `repl_snapshot` + `flared --dump-checkpoint` (§12; `dump`
   changes a master and makes the scan UNKNOWN). Capturing a real cluster
   is NOT approved; `scripts/flare_v_capture_kind.py` refuses any context
   but kind.
3. Only on MATCH: set `spec.forwardApproval` to the printed approval line.
   One use: the line a switch was issued with is recorded in
   `status.forwardApprovalConsumed` and refused again.
   The switch is issued only when, in the same tick, EVERY source pod (any
   role) reports `cluster_replication on`, mode `duplicate` and no
   asynchronous forward in flight: `cluster_replication_forward_in_flight`
   is 0 AND `cluster_replication[forward_enqueued]` EQUALS the sum of its
   outcomes (applied, noop_*, missing_*, failed_*, dropped_{abandoned,
   down, stopping, retries, unknown_op}). Otherwise "switch precondition:
   …". A reply the operator does not trust holds the switch, and the
   operator log says why ("replication state not trusted (…)"). Such a reply
   is incomplete, carries a non-numeric or unknown counter, repeats a name,
   or lacks the in-flight gauge (a flared older than 4ceabfb).
4. Keep writes stopped until the phase is **AwaitingCutover**. Pods apply
   forward one by one (ConfigMap + SIGHUP each, up to ~2 min apart); in
   between some pods answer clients from the target and others from the
   source. With writes stopped both hold the same data; a write in that
   window can be served from one side only, read stale through the other,
   or overwritten by an older asynchronous forward. The operator advances
   only when every pod REPORTS forward (not the rendered config), nothing is
   in flight, and the approval still holds against the live masters; a
   moved position holds it in Forwarding ("re-run V and set a new
   forwardApproval"). It detects such a write — it cannot undo what a
   client already saw. Abort is refused there (#migration-forward-abort).
5. Resume writes after AwaitingCutover.

If held in Forwarding by a moved position: keep writes stopped; do NOT set
the source back to duplicate (pods already in forward hold target-only
writes); capture both sides again and run V. MATCH → set the new line (it
advances). DIFFERENT → the listed keys need a decision (repair R is not
implemented); the migration stays held.

A source that already shows forward (rendered, or any pod applying it)
while the phase still says Duplicating — e.g. the operator crashed between
the CR patch and its status patch — moves to Forwarding with no action;
abort is refused from then on in every phase.

`status.message` names the condition that holds. Nothing here repairs a
difference or re-seeds; R (repair) stays a separate, approved procedure.

### Cross-cluster seed without snapshot push (opt-in) {#cross-cluster-per-key-only}

`spec.clusterReplication.snapshotPush: false` makes every cross-cluster
seed a per-key merge dump: the destination keeps its own history, so a
destination master restart is an ordinary restart (with a snapshot push the
destination takes the source's history and, today, stays masterless after a
restart — review-cross-cluster §10/§13, unresolved). Default unchanged
(true). Set it together with `enabled: true` (it is read when a seed starts;
a running seed is not affected). Needs a flared that knows
`cluster-replication-snapshot-push`: an older flared rejects the config.
Check: source stat `cluster_replication_snapshot_push off`, seed state
`completed_dump`, `cluster_replication[seed_snapshot_push_disabled]` moved,
destination `rocksdb_snapshot_bootstrap` unchanged. Costs: a slower seed
and `dump` on the source master (reaps expired keys, takes the iteration
slot and the whole-DB read lock for the seed). Choosing it for a real move
is a decision that has not been made.

### First cross-cluster move: per-key seed under an explicit write stop {#initial-migration}

Method approved for development and verification (user, 2026-10-13). Not
approved: any change to a real environment, pf-dev, real data, capture of a
real cluster, the web switch, or a destructive step. Every step below is a
human act unless it says the operator does it.

**Seed: per-key only.** The snapshot-push seed and its history adoption
(A/B, cluster-replication-faults T4/T5 = X4) are OUT of this move; their
known defects stay open and are not closed by it. The push path is closed by
configuration on BOTH sides:

| Side | Setting | Check before any seed |
|------|---------|-----------------------|
| every source CR that targets the destination | `clusterReplication.snapshotPush: false`, set before or with `enabled: true` (a FlareMigration's `startDuplicate` merge patch keeps it) | source stat `cluster_replication_snapshot_push off` on every source pod |
| destination CR | `clusterReplication: {enabled: false, snapshotPush: false}` (a FlareMigration provisions this itself when its source has `false`, ee13ef8; the operator renders the switch with replication off only from be60dbb — an older operator drops it) | destination stat `snapshot_push_accept off` on every destination pod; a hand-sent `repl_snapshot_push` is answered `SERVER_ERROR snapshot_push_disabled` (be8831d) |

After the seed: `cluster_replication_seed completed_dump`,
`cluster_replication[seed_snapshot_push_disabled]` moved, destination
`rocksdb_snapshot_bootstrap` unchanged, destination master id / copy id
unchanged. Any check not met → set `enabled: false` on the source and stop;
nothing on the destination is of record yet. A source flared older than
feec633 does not know `cluster-replication-snapshot-push` (it rejects the
config line): the destination's refusal still holds (from be8831d), but the
source's own seed behaviour is then not controlled — decide before such a
move.

**Write stop: explicit, from before content verification until the switch is
complete.** flared has no write fence or read-only mode, and the operator
cannot see a fence (it only sees positions). Unchanged counters are a CHECK
of the stop, never the stop itself. The automatic write fence is not
implemented; this runbook does not claim it.

Writers to stop (all of them; a writer not listed here is a reason to stop
the move):

| Writer | Writes by | Stop by | Confirm by |
|--------|-----------|---------|------------|
| Application clients (web, batch, cron, workers) | set/add/replace/cas/append/prepend/incr/decr/delete/touch/gat (+ binary q-variants) | the owner of each client, from an inventory signed off before the window | owner's confirmation per client; then the positions below |
| People and tools (nc, flare-tools, scripts) | the same commands, `flush_all`, `orphan_purge` | access withdrawn for the window | named in the sign-off |
| `flush_all` | truncates a master (not mirrored cross-cluster) | `spec.rocksdb.flushAllEnabled: false` on source and destination | reload notice on every pod |
| Expire reaper (active master) | versioned deletes (mirrored) | **no CR field**; `reap-expired` is a flared option only | its deletes move the source position → the forward gate holds (see gap W1) |
| Lazy expiry on reads (master) | a read of an expired key deletes it (WAL only, not mirrored) | cannot be stopped while reads continue | moves the position → gate holds (gap W1); V reads a checkpoint, unaffected |
| Cross-cluster forwarder | the move itself, into the destination | — | `cluster_replication_forward_in_flight 0` and `forward_enqueued` = sum of outcomes on every source pod (the operator checks this at the switch) |
| Restore / bootstrap / orphan purge / rebuild operations | replace or remove data | none started in the window | no `rebuild_in_flight`, no restore in progress |
| Anything writing to the DESTINATION directly | — | the destination is not in service before cutover | destination positions move only with the forwarder |

Confirm the stop, all required, before capture/V:
1. every row's owner has confirmed; the inventory is attached to the record;
2. over an observation interval, every source master's
   `rocksdb_latest_sequence_number`, `cmd_set`, `delete_hits+delete_misses`
   and `curr_items` do not move (corroboration only — a writer the inventory
   missed that wrote nothing in the interval is not detected);
3. no forward in flight (row "Cross-cluster forwarder").

Then the forward-switch procedure (#migration-forward-gate): capture + V,
`forwardApproval` on MATCH only, writes stay stopped until
**AwaitingCutover**.

Resume writes only when the phase is AwaitingCutover (or, without
FlareMigration, after clients point at the destination); resumed clients use
the destination endpoint (a source in forward mode proxies to it).

Abort / roll back:
- **Before the forward switch** (V DIFFERENT, a check unmet, a hold you do
  not resolve): set the source's `enabled: false` (or abort the
  FlareMigration), keep the source as the system of record, resume writes
  on the source. The destination holds nothing of record; discard it.
- **Held in Forwarding by a moved position**: keep writes stopped; do not
  set the source back to duplicate; capture again and run V. MATCH → new
  approval line; DIFFERENT → stays held; the listed keys need a decision
  (repair R is not implemented).
- **After the forward switch**: abort is refused; there is no automated way
  back (the target holds writes the source acknowledged). A procedure that
  first moves those writes back does not exist — decide before the move.
- **After cutover**: the source is stale.

Open for this move (not closed by this runbook):
- **W1** expiry writes the stop cannot prevent (reaper without a CR switch,
  lazy expiry on reads). They hold the gate; whether to stop the reaper by
  a CR field or to accept repeated V is a decision.
- Capture on a real cluster (V needs it) is not approved; the capture
  driver refuses any context but kind.
- No automatic write fence; a NetworkPolicy fence would also cut reads and
  replication and is not designed.

### Intra-cluster replication after the move: hybrid {#post-migration-hybrid}

The destination runs **hybrid** in-cluster replication: the immediate
forward to replicas (op proxy) **and** a continuous WAL follower
(`spec.rocksdb.replIdentityForward: true`, `replFollowEnabled: true`, with
`readUnavailableError: true`). On a new cluster set all three at creation
(the chart examples do); on an existing one follow #enable-follow. WAL-only
streaming and low-latency push are a separate release; recovery from a cut
is NOT deferred — it is what the follower does.

Do not confuse the two deliveries: the cross-cluster move delivers PER KEY
(seed dump + mirrored writes, source → destination cluster); in-cluster
copies are kept by the forward plus the WAL follower (master → its
replicas).

What is accepted for production (one E2E run, continuous-replication
"ACCEPTANCE: …", b5b218a): same master and history, WAL still held; both
paths cut; creates/updates/deletes during the cut; writes stopped; healed →
the replica resumes from its applied cursor, no reconstruction / dump
fallback / container restart / pod recreation, every key equal. While it
lags, a replica read is the master's value when the master is reachable and
`SERVER_ERROR` when not — never its stale copy, never END. The cut is a kind
iptables cut: it is evidence for a network partition, not for a real AZ
failure.

Cases that need a rebuild (recorded separately, not this acceptance):
WAL retention exceeded (`needs_rebuild`/`lsn_purged`, E2E
continuous-replication-purge T6, outage phase B), failover to a new master
(survivors rebuild against the new history, E2E "planned promotion"), copy
loss (empty or unusable store → full rebuild; tmpfs: data since the last
backup is lost, #restore-in-place).

**Loss on master loss.** Replication is asynchronous. A master that dies
holding writes not yet on any replica takes them with it: zero loss is NOT
guaranteed, and WAL-only streaming would not change that. The default
last-resort promotion (`FLARE_FOLLOW_FAILOVER_WAIT_SECONDS`, an unfit copy
promoted after the wait) is LOSSY by design — never describe it as lossless.

### Abort after the forward switch {#migration-forward-abort}

Refused in Forwarding and AwaitingCutover (before: allowed). doAbort
deletes the target, which by then holds writes the source acknowledged in
forward mode and does not have — an abort there would lose them. There is
no automated way back from forward; a human decision (and a procedure that
first moves the target's writes back) is needed.

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

## Topology observation

Alerts: `FlareTopologyDeliveryLag`, `FlareTopologyGenerationMismatch`,
`FlareTopologyFeedbackUnknown`. Gauges count mapped nodes whose last usable
observation is behind/ahead of the committed version, or whose feedback is
missing, invalid, or over 60 seconds old. Counts are refreshed each reconcile;
an operator stall can freeze them. Monitor operator availability and reconcile
progress as well. A zero count is not proof of data equality or safe promotion.

1. Inspect `[TopologyAudit]` logs for node key, Pod UID, desired/reported
   version, and verdict. Check that the operator still holds its Lease.
2. For lag, inspect delivery/retry logs and the operator-to-node network path.
   Restoring connectivity should allow fenced retry; do not delete the copy.
3. For Unknown, check API/exec permissions, stats completeness, Pod replacement,
   and reconcile duration. One node is audited per pass: large clusters can
   exceed the 60-second coverage window even without a failed node. Measure
   audit coverage before deployment; do not suppress the alert as "healthy".
4. For ahead, investigate competing leaders, Lease deletion/recreation and
   persisted map history. Preserve evidence and stop rollout. Do not reset
   recipient versions or force a larger operator version to silence the alert.
   Generation recovery remains an open SAF-09 task.

These signals must not automatically cause failover, promotion, Pod deletion
or data reconstruction. Missing observations are not proof of node failure.

## Authoritative history record {#history-record}

The operator keeps each partition's accepted history in the ConfigMap
`<cluster>-history` (docs/design-authoritative-history.md). It never adopts or
overwrites a record it cannot trust:

- **corrupt / unreadable / foreign** (another FlareCluster uid — e.g. the CR was
  recreated): the operator logs CRITICAL "record is not usable" and holds
  promotions and rebuilds of the cluster. Inspect the record; if it is not
  needed, delete it, then give the migration approval below.
- **absent with a node map** (an operator release without the record, or a lost
  record): nothing is adopted automatically. Approve the migration for THIS
  cluster, after checking that every copy is healthy and the current master
  holds the data:

  ```
  uid=$(kubectl -n <ns> get flarecluster <cluster> -o jsonpath='{.metadata.uid}')
  kubectl -n <ns> annotate flarecluster <cluster> --overwrite flare.gree.net/history-adoption-approved=$uid
  ```

  The record is then adopted from the current master once every copy of the
  partition has been observed (an empty master while another copy holds data,
  or any copy unreadable, is never adopted).

  **Upgrading flared from a release without copy evidence (rc56 / older):**
  roll the flared pods only AFTER every partition shows its decision in
  `<cluster>-history` — `part N untracked` (every copy still on the old
  flared) or `part N known`:

  ```
  kubectl -n <ns> get configmap <cluster>-history -o jsonpath='{.data.record}' | grep '^part '
  ```

  Rolled earlier, a partition whose copies are mixed (a new replica, the old
  master) is HELD ("the master ... is not a modern, observed copy"), and when
  the master's own roll brings it back empty (tmpfs) the replica's promotion
  is ABORTED ("authoritative history is absent"): the partition has NO master
  and writes to it fail (CI 38072338837). Stop the roll there. Recovery:
  name the replica that holds the data — #history-held-masterless (that
  recovery is NOT yet exercised by a test for this mixed-version state).

### Rolling the operator back past the history record

The node map now carries `transition=<id>` lines. An older operator's strict
startup validation rejects them (it halts with "node line does not parse").
Do NOT delete the node map to roll back. Roll back only when no history
intent is pending (`intent` lines absent from `<cluster>-history`), with this
operator stopped: remove ONLY the `transition=` lines from the `nodeMap` data of
`<cluster>-node-map`, then deploy the older operator. Going forward again
needs the migration approval (#history-record).

## A partition held by its history {#history-held}

`part N known ... <hold>` in the record (and CRITICAL "is HELD" on a
promotion): the retained record is kept, and promotions, new intents and
rebuilds of that partition are refused until the hold is resolved.

- **bulk part-way** (flush_all / truncate seen before its receipt): it lifts by
  itself when flared's receipt arrives (`rocksdb_bulk_chain`). If it does not
  (the bulk crashed part-way), the holder's copy is not provably the recorded
  one: decide from the data, not from the record.
- **intent held** (the promotion target restarted / was replaced, is unhealthy,
  or is not master in the committed map): the target's new history was never
  adopted. Inspect the target's copy; the resolution is an operator decision
  (remove the hold only after the partition's data is understood).

### The recorded master moved to a new epoch in place {#history-holder-reseated}

Symptom: the master IS the record's holder (`part N known <gen> <masterId>
<epoch> <holder> ...`), but its `rocksdb_source_epoch` is newer than the
recorded epoch, and every replica of the partition is logged
`REBUILD HELD (history): ... holds another history than the record` — the
replicas stay proxies, so **the master accepts writes with no replica**.
Seen in CI 38081479454: a stale node map made the master leave its role and
be re-seated (a new epoch, same copy) right after the first-build record was
taken. The operator does not re-adopt this by itself (a new epoch on the
holder is only an observation unless it is a proven bulk).

Recovery — only after checking that the master holds the partition's data
(items, a sample of keys) and no other copy holds more:

1. Save the record: `kubectl -n <ns> get configmap <cluster>-history -o yaml > history-<date>.yaml`.
2. Delete the record: `kubectl -n <ns> delete configmap <cluster>-history`
   (EVERY partition of the cluster becomes Unknown/absent; their promotions
   and rebuilds stay held until each is re-adopted from its own master).
3. Give the migration approval (#history-record). The record is re-adopted
   from the current master once every copy was observed, and the replicas'
   rebuilds are assigned. Exercised: history-tracking (3a) brings the master
   to another history than the record (flush_all while the record cannot be
   written) and logs this section's symptom before the recovery (CI
   38099482037: 10 `REBUILD HELD (history)` lines), then deletes the record
   and gives the approval; the record is re-adopted, and the next test
   requires the replica rebuilt onto it within 240 s (passed). NOT exercised:
   the same recovery after a re-seat with a new epoch (how this section's
   state arose in CI 38081479454) — no deterministic reproduction; the
   operator path from the symptom on is the same. Step 1 (saving the record)
   is not exercised.

Do not delete the record while a promotion intent is pending (`intent` lines)
or while the master's copy is in doubt — stop and keep the evidence.

## A partition with no master and no history record {#history-held-masterless}

Seen as: `CRITICAL: partition N has NO master and its history is HELD: <reason>`
(repeated every 15 s while it stands), after a node map was restored without a
history record. A typical cause is a FlareCluster recreated (a new uid, the old
record removed as foreign) with the map restored: every pod re-registers, so the
restored map's master becomes a replica marked `lastMasterOf=N`.

With the migration approval (#history-record) the operator recovers BY ITSELF
only when the history is unambiguous:

- every copy of the partition was read completely,
- every copy is a healthy RocksDB copy holding the SAME history (master id and
  epoch: `rocksdb_master_id`, `rocksdb_source_epoch` in `stats`),
- exactly one copy is marked as the partition's last master.

It then records the history from that copy and promotes as usual. Anything else
is HELD on purpose: choosing between histories decides which data survives, and
the operator never guesses. The CRITICAL line names the reason and every copy
with its history:

| Reason (in the line) | What to do |
|---|---|
| `not every copy of the partition was observed completely` | A copy cannot be read (its pod is down, or the operator lacks access, e.g. RBAC). Restore access; the hold lifts by itself once every copy is read. |
| `no master to take the history from (... one history on every copy and exactly one last master)` | The copies hold DIFFERENT histories, or the map marks no / several last masters. A person decides — below. |
| `no master, and not every copy is a healthy modern copy` | A copy is quarantined, partial or an older flared. Fix or replace that copy first. |
| `no master, and the last master <key> is not an observed copy` | The map's last master is not among the partition's copies now. A person decides — below. |

**Choosing the copy to keep** (only for a held partition with no master):

1. From the CRITICAL line and each pod's `stats`, decide which copy holds the
   data the partition must keep (its history, `curr_items`, the time it last
   served as master). The other copies will be rebuilt from it — their data
   that is not in the chosen copy is lost.
2. Keep the migration approval in place, and name the copy for THIS cluster:

   ```
   uid=$(kubectl -n <ns> get flarecluster <cluster> -o jsonpath='{.metadata.uid}')
   kubectl -n <ns> annotate flarecluster <cluster> --overwrite \
     flare.gree.net/history-adopt-holder=$uid/<partition>/<pod name or node key>
   ```

3. The operator adopts the chosen copy's history (`AUTHORITATIVE HISTORY: pN:
   adopted from <copy>, CHOSEN by a person`), removes the annotation (a choice
   is used once), and promotes it; the other copies rejoin and are rebuilt
   from it.

A choice is evaluated ONCE and then removed, whatever the outcome — so a
choice can never wait and apply later to a copy that has changed since:

- REFUSED (CRITICAL `the history-adopt-holder choice ... was REFUSED: <reason>`;
  the hold stays) when any copy is unreadable, the name matches no copy of the
  partition (a typo, a wrong port), the chosen copy is unhealthy, or it is
  EMPTY while another copy holds data. Fix the cause, check the copies again,
  and annotate again.
- REMOVED without effect when the partition is not held without a master (it
  has a master or a record), or the migration approval is missing (a
  separate CRITICAL says so).
- If the removal itself fails, the choice is NOT applied again and the removal
  is retried (CRITICAL `could not remove the history-adopt-holder choice`).

## Writes dropped to a destination outside this cluster {#foreign-drops}

Seen as: `CRITICAL: writes were dropped to destination(s) outside this cluster`.
A master counts every write it acknowledged but could not deliver to a
downstream copy (`proxy_write_dropped[<host:port>]` in its `stats`). When that
destination is not a node of this cluster — cross-cluster replication to
another cluster — this operator cannot repair it, and the destination cluster's
operator never reads this master's counter.

- The destination cluster's copy lacks those writes until it is rebuilt.
- Decide from the destination's data: rebuild the affected destination from
  this cluster (the cross-cluster seeding procedure), or accept the gap.
- The entry stays in this cluster's repair ledger
  (`status.replicaRepairs`) as unresolved; it is evidence, not a request this
  operator will act on.

Before an ingest or a cutover that relies on the follow (see
docs/review-cross-cluster-2026-10-11.md):

- Any increase of the source masters' `proxy_write_dropped[<destination>]`
  after the seed means the destination lacks acknowledged writes: **do not
  cut over.** A destination that restarted empty is NOT detected by any
  counter — check its item count against the source.
- Since 4024a6c a destination's non-success answer is counted too, per op
  (`cluster_replication[forward_failed_<op>_<result>]`); `set NOT_STORED` and
  `delete NOT_FOUND` are idempotent answers and are NOT counted
  (`forward_noop_*`); `touch NOT_FOUND` (`forward_missing_*`) means the
  destination lacks a key the source holds — a divergence signal. A forward
  with no answer is retried for up to 120 s before it is counted
  (`forward_dropped_retries`; later ones `forward_dropped_down` until the
  destination answers again).
- The seed's state is `cluster_replication_seed` on each source master:
  anything but `completed_snapshot_push` / `completed_dump` means the
  destination does NOT hold the data that existed before the enable
  (`failed_connect`: never started; `failed_transfer`: partly copied).
- Verify the destination's contents against the source with writes stopped
  before a cutover — counts and drop counters say how many, never which
  keys (procedure V in docs/review-cross-cluster-2026-10-11.md §7.5).
- The only repair is a full re-seed: wipe the destination partition, then
  `spec.clusterReplication.enabled` false → true (snapshot-push refuses a
  destination holding more than 4096 items; the merge dump never deletes
  and aborts on a populated destination — §7.4). Wiping is destructive,
  needs an explicit approval, and is NOT exercised end to end.

## The leader steps down by itself when its lease cannot be renewed {#lease-failclosed}

The operator keeps a LOCAL lease deadline on the monotonic clock
(`StateMachine/LeaseGuard`): `heldUntil` = the SEND point of the last positively
confirmed hold + 15 s lease − 3 s margin. Confirmed = a renew/acquire write that
returned success, or — after a timeout / lost response — a read-back that shows
this pod as holder AND the exact `renewTime` that attempt wrote. An unreadable
lease, this pod with an older `renewTime`, or an expired lease naming this pod
extend nothing. A background renewer attempts every 5 s (each API call bounded to
min(4 s, time left)); a watchdog independent of the API checks the clock every
500 ms. When the deadline passes (or another holder is seen) the leader at once:
stops answering index requests, reports `leader=false`, labels itself `standby`
(best effort, ≤ 1 s) and exits (`LEASE FAIL-CLOSED: ... LOST LEASE`). The
authority fences (history write, authority pass, broadcast, eviction commits)
also require the local deadline.

- Log: `LEASE FAIL-CLOSED: <why>`; the Deployment restarts the pod, which
  returns as a standby. One such line with an API outage / network cut is the
  design working; repeated lines without an outage: check API latency
  (`lease guard started` / renewer attempts, `kubectl --request-timeout` errors)
  and clock behaviour on the node.
- Safety argument: a new leader can take the lease only after it LOOKS expired
  on the API server (`renewTime + 15 s`, takeover CAS by resourceVersion). The
  `renewTime` this pod wrote is taken after its send point, so server expiry ≥
  send + 15 s, while this pod stops serving at send + 12 s (+ ≤ 0.5 s watchdog,
  + ≤ 1 s step-down): before any new leader can hold. Assumptions: bounded
  clock-RATE drift (the 3 s margin covers about 25 %) and bounded wall-clock
  offset between the pods' clocks for the expiry judgement; our own deadline
  uses the monotonic clock only.
- E2E: `operator-lease-failclosed` (control with 16 s passes; stalled lease API
  of the leader, timestamps). Test seams (never set in production):
  `FLARE_TEST_LEASE_API_STALL_FILE`, `FLARE_TEST_RECONCILE_PASS_DELAY_FILE`.

## Known limits (do not be surprised by)

- Selective network partition (pod alive, TCP to operator blocked) is
  mitigated (per-tick rebroadcast, lease fence) but not fully modeled —
  a wedged-but-probe-passing flared is not failed over automatically.
- Multi-partition restore requires manual partition-affinity verification
  (BACKUP_RESTORE.md Case C) until partition pinning is implemented.
- Config changes: hot-reloadable options land within ~2min (kubelet
  propagation + verified re-SIGHUP); WAL-retention/cache options need a pod
  restart — the operator logs which is which.
