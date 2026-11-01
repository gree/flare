# Flare Operator Runbook

## Upgrading a release (READ THIS FIRST) {#upgrading}

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
# Helm >= 3.14: the new chart's defaults, then the release's values on top
helm upgrade flare ./helm/flare-operator -n flare-system --reset-then-reuse-values \
  --set image.tag=<version> --set cluster.image.tag=<version>
# or pass the release's values file explicitly (no --reuse-values):
helm upgrade flare ./helm/flare-operator -n flare-system -f <values.yaml> \
  --set image.tag=<version> --set cluster.image.tag=<version>
# CRDs upgrade in-band because crds.install defaults to true.
```

**Do not use `--reuse-values` for the first upgrade from rc68 or older.** It
builds on the old release's values and ignores the new chart's defaults. The
values added since rc68 (`nodeGuard`, `nodeReplacement`, `legacyMasterSwitch`)
are then missing: the templates that read them fail to render, or render
with the node guard and the cordon move off. Check the rendered result
before applying (`helm template` / `helm diff`): the operator Deployment has
`FLARE_NODE_GUARD=on` and the `<release>-flare-operator-node-guard-<ns>`
ValidatingWebhookConfiguration exists.

**What the upgrade does to the flared pods.** The flared StatefulSet uses
`updateStrategy: OnDelete`: applying the chart replaces no pod. The operator
replaces the pods that are not on the StatefulSet's update revision, one at a
time, the highest ordinal first and a master last through the ordered
handover, and only while every partition has its master and its replicas
Active, Ready and caught up (details: [node guard](#node-guard)). Follow it in
the operator log:

```bash
kubectl -n <ns> logs deploy/<release>-flare-operator | grep 'ROLLING:'
#   ROLLING: delete <pod> (...)                 one pod replaced
#   ROLLING: waiting (...)                      why it is not replacing now
#   ROLLING: idle (every pod is on the update revision)   done
kubectl -n <ns> get sts <cluster>-nodes -o jsonpath='{.status.updateRevision}'
kubectl -n <ns> get pods -l app=flare -L controller-revision-hash
```

It is done when every flared pod's `controller-revision-hash` equals the
update revision. To stop it, set `FLARE_OPERATOR_ROLLING=off` in the
operator's `env` (values `env:`); pods are then replaced by hand, one at a
time, with graceful deletes ([node guard](#node-guard)). With `replicas: 1`
(no replica) a master has nobody to hand over to: rolling waits on it and
the master is not replaced.

**First upgrade from rc68 or older: `legacyMasterSwitch`.** A master running
an rc68-or-older flared cannot be handed over without possible loss, so by
default the operator does not replace it: rolling waits with
`ROLLING: waiting (master … runs a flared from before the ordered handover …)`
and the node guard refuses its delete. To accept that risk for this upgrade:

1. Upgrade with `--set legacyMasterSwitch=true` (operator env
   `FLARE_OPERATOR_LEGACY_MASTER_SWITCH=allow`).
2. Wait out the operator's startup grace (`FLARE_STARTUP_GRACE_SECONDS`,
   default 120 s, counted from when it became leader). Until then the log
   says `… it is replaced only after the operator's startup grace, when the
   drain is active` and nothing is deleted.
3. Each such master is then deleted for the drain's promotion, only while a
   caught-up replica exists (`ROLLING: delete … NOT loss-free`). Writes the
   master acknowledged but had not forwarded can be lost.
4. Once every flared pod runs the new release (`ROLLING: idle (every pod is
   on the update revision)`), upgrade again with `legacyMasterSwitch=false`.

See also [Upgrading from rc68 or older](#node-guard) under the node guard.

**The default copy count is now 3 (`cluster.replicas`, was 2).** A release
that never set `cluster.replicas` gets one more flared pod per partition on
this upgrade (memory and pods x1.5); the new pods join as replicas and
rebuild from their masters. To keep 2 copies, set `cluster.replicas: 2`
before upgrading — cordon moves are then blocked unless
`nodeReplacement.minCopies: 2` ([cordon moves](#cordon-move)). A release that
sets it already (pf-dev) is unchanged.

**The webhook during an upgrade.** The node guard judges StatefulSet UPDATEs
too (`failurePolicy: Fail`). An update that does not reduce `replicas` is
allowed, but while no operator leader answers (for example the operator
Deployment is rolling in the same upgrade) the call itself fails and Helm
reports `failed calling webhook "statefulsets.node-guard.flare.gree.net"`.
Run the same upgrade again once the operator is Ready.

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

### Rolling a release back {#rollback}

**A `helm rollback` to rc68 or older is not loss-free.** The rc68 chart has
no `updateStrategy`, so the StatefulSet goes back to the Kubernetes default
`RollingUpdate`, and the node-guard webhook is removed. The StatefulSet
controller then replaces EVERY flared pod itself, highest ordinal first,
masters included, with no ordered handover: each master goes through the
drain's promotion, and acknowledged writes it had not forwarded can be lost.
On tmpfs every replaced pod also reseeds its copy. Nothing stops it: the
webhook is gone, and the StatefulSet controller is a trusted requester anyway.

Before any rollback:

- No cordon move in progress: `kubectl get flarecluster <name> -o
  jsonpath='{.status.nodeMoves}'` shows no move other than `done` /
  `cancelled` (uncordon and wait, or let the moves finish).
- No handover running (`HANDOVER` in the operator log) and no rolling in
  progress (the last `ROLLING:` line is `idle (…)`).
- Take a backup (docs/BACKUP_RESTORE.md).

Prefer, when only the operator has to go back: keep the new chart and roll
back only the operator image, with the features it does not have turned off.

```bash
helm upgrade flare ./helm/flare-operator -n <ns> --reset-then-reuse-values \
  --set image.tag=<old version> \
  --set nodeGuard.enabled=false --set nodeReplacement.enabled=false
```

The StatefulSet stays `OnDelete`, so no flared pod is replaced. An rc68 or
older operator does not replace pods (it has no rolling) and does not serve
the webhook, so `nodeGuard.enabled=false` is required (otherwise every flared
pod delete and every eviction in the namespace is refused); the chart
refuses `nodeReplacement.enabled` without the guard. Any flared change after
that is by hand: graceful deletes, one pod at a time, a master last. This
combination is not exercised by a test.

The node map format is unchanged since rc68. For an operator older than the
history record, see
[Rolling the operator back past the history record](#history-record).

## On-call overview {#on-call}

On-call procedures for the Lean-operator-managed Flare cluster. Alert names
match `helm/flare-operator/templates/prometheusrule.yaml` (the chart's rules).
`deploy/monitoring/prometheus-rules.yaml` holds only five of them
(MasterMissing, CircuitBreakerTripped, PrepareStuck, OperatorAbsent,
DeadNodeChurn); use the chart's rules.

Quick orientation:
- Control plane = the operator (leader-elected, FSM tick every 5s). Data
  plane = flared pods (StatefulSet `<cluster>-nodes`). **The data plane keeps
  serving with its last topology even if the operator dies** — control-plane
  incidents are urgent but not instant data outages.
- The operator's view: `printf 'node sync\r\n' | nc <operator-svc> 12120`
  (roles: 0=master 1=slave 2=proxy; states: 0=active 1=prepare 2=down).
- Useful log greps (operator): `CIRCUIT BREAKER TRIPPED`, `LEASE CHECK`,
  `LEASE FENCE`, `WARNING: node .* Prepare`, `Promoting Slave`,
  `topology changed` ([lease check](#lease-check) explains the two LEASE
  lines).
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
3. While no operator leader answers, the node guard fails closed: flared pod
   deletes, every eviction in the namespace (`kubectl drain` included) and
   StatefulSet updates are refused. See
   [The operator is down](#node-guard-operator-down).

## `LEASE CHECK: authority NOT confirmed` (mid-pass lease check) {#lease-check}

The leader renews its 15 s lease at the top of every pass, but a pass can
outlast it. So right before each action that only the leader may take — a
topology broadcast, a write of the authoritative history, a step of an
ordered handover (and a rolling or cordon-move delete), the empty-master
self-heal delete — the operator re-checks the lease **now**
(`holdLeaseNow`, `StateMachine/LeaseFence.lean`): it reads the lease and
renews it. The lease counts as held only when

- the lease still names this pod as holder, **and**
- the renew succeeded, **and**
- at least 5 s of the 15 s lease are left, counted from **before** the renew
  was sent (the renew must answer within 10 s).

A failed or late renew is **not** held: the read before it is no evidence
once the call took that long, and a standby may have taken the lease
meanwhile. The gated action is then skipped and retried on the next pass;
nothing is lost, it is only delayed. Logs:

```
LEASE CHECK: authority NOT confirmed — the renew took <ms>ms, less than 5000ms of the 15s lease left; the gated action is skipped
LEASE CHECK: authority NOT confirmed — the renew failed after <ms>ms (<error>); the gated action is skipped
```

followed by the caller's line, e.g. `LEASE FENCE: the lease was not confirmed
(…) — suppressing topology broadcast (vA → vB); held for retry`,
`LEASE FENCE (<why>): the lease was not confirmed (…); v<N> held for retry`,
`CRITICAL: the authoritative history is NOT written: this pod's lease was not
confirmed …`, `ROLLING: the lease could not be confirmed …` or `NODE MOVE:
the lease could not be confirmed …`. A `LEASE FENCE` line **without** a
`LEASE CHECK` line just before it means the lease read named another holder
(a real leadership change: expect `LOST LEASE -- exiting` at the next loop
top and a restart, see [operator-down](#operator-down)) or the lease could
not be read at all (`lease fence …: getLease failed (…)` just before it).

What it means operationally: almost always a **slow kube API** (the renew is
one PATCH). The leader normally keeps its lease — it renews again at the top
of the next pass — so a single line is harmless. **Repeated lines** mean the
API server answers slower than ~10 s: while it lasts, map broadcasts,
history writes and handovers stay held (the data plane keeps serving the last
map), so failovers are delayed. There is no metric and no alert for it; check
the apiserver (latency, throttling, etcd) and the operator pod's network.
Do not restart the operator for it: a new leader faces the same API.

## FlareDeadNodeChurn (warning) {#dead-node-churn}

Repeated dead-node detections without a breaker trip: usually crash-looping
flared pods (OOM, bad storage) or node pressure. Check pod restart counts
and events; fix the underlying cause. Churn is safe for data (promotion
only ever selects live, data-bearing replicas) but each cycle costs
reconstruction bandwidth.

## FlareNodeUnhealthy (critical) {#node-unhealthy}

A node's POD IS PRESENT but it stopped being Ready long enough that the
operator treated it as dead and failed over. The gauge
(`flare_operator_nodes_unhealthy`) counts NotReady nodes only: a Ready node
the operator cannot connect to is
[FlareNodeUnreachableFromOperator](#node-unreachable) instead. This is NOT a rescheduling
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
3b. **If the log says the master was KEPT** (`CRITICAL: master <key> is NOT
   SERVING or UNREACHABLE … has NO reachable promotable successor — kept as
   master`), the partition has no replica to promote, so the
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
Ready. The node may well be serving clients — what is broken is at least the
**operator→pod path**, so topology pushes are not landing and that node
keeps running on whatever map it last received. Since spec 12 the operator
also acts on it (below): the alert's summary says when it did not fail the
node over (a master kept without a reachable successor, or the guard: no node
reachable).

Nothing else sees the path itself: the readiness probe runs inside the pod
(kubelet asking flared about itself) and the operator's stats probes travel
through the API server, so both stay green.

**What the operator does (spec 12, as the EC2 index server does).**

- **Probe.** At most once per 5 s, the operator lists the flared pods and
  opens a TCP connection to port 12121 of every Ready, non-Terminating pod of
  that same listing (1 s timeout). The probe is a connect only: a flared that
  accepts connections but does not answer is not detected here. If the
  listing fails, nothing is probed and nothing is decided that round
  (`reachability: pod listing failed (...) — no probe and no down decision
  this round`). A failure streak belongs to one pod UID: a recreated pod
  starts from zero.
- **Down after 3 failed probes in a row** (~15 s), for an Active master or
  slave:
  - a **slave** is marked down (proxy) and the rebuild path builds another
    copy: `UNREACHABLE: <key> (<role>) failed 3 consecutive operator probes —
    marked down (proxy) …`;
  - a **master** is marked down only when the failover itself would promote
    a successor (`UNREACHABLE: master <key> failed 3 consecutive operator
    probes — marked down if a reachable slave of its partition can be
    promoted, otherwise kept as master …`). The decision and the promotion
    use the same candidate list (`K8sReconciler.failoverCandidates`): an
    Active slave of the partition whose pod is present, not itself
    unhealthy, unreachable or down, with no replica repair held on it, not a
    follower known unfit (continuous-replication evidence, R3 source
    eligibility 0 or unreadable, a promotion-evidence class other than
    eligible / legacy / empty, pod not Ready) and not promotion-blocked. An
    unproven follower or a standby slave still counts (tried last; an
    unproven one is logged `PROMOTION NOT LOSS-FREE`). The masterless
    refill's choices (a Prepare or data-bearing last resort, the history
    holder) do not count: the refill commits after the demotion, so a
    refusal there would leave the partition without a master. Without a
    successor the master is **kept**: `CRITICAL: master <key> is NOT SERVING
    or UNREACHABLE … has NO reachable promotable successor — kept as
    master`.
  - **What the check cannot see:** the refusals the commit makes from fresh
    reads (R3 unreadable at commit, the successor's pod / boot / copy
    changed since it was read, a different classification at commit, the
    authoritative history not KNOWN, HELD, an intent pending or not
    persistable). Each aborts the whole pass (`CRITICAL: PROMOTION ABORTED
    for <key>: … nothing from this pass is committed`), the demotion
    included: the old master stays master in the map and the next pass
    decides again. The partition is not left masterless, but it serves
    nothing while the aborts repeat; the abort message, not the "kept"
    message, is then the signal.
  - Down nodes go through the same dead detection as NotReady ones, so the
    [circuit breaker](#circuit-breaker) applies to them too.
- **Guard: no node reachable.** When every probed node fails, the fault is
  taken to be on the operator's side (API, network): nothing is marked down,
  no master is promoted, and every streak restarts. Log:
  `CRITICAL: the operator cannot reach ANY of the N flare node(s) it probed …
  NO node is marked down and no master is promoted (alert only) until a node
  answers`. The gauge `flare_operator_no_node_reachable` is 1 meanwhile and
  the alert `FlareOperatorReachesNoNode` fires after 2 min (spec 12: alert
  only). Check the operator pod's network and the API server first; the flare
  nodes themselves are probably fine.
- **Back again.** A node marked down for unreachability that answers the
  latest probe round again is restarted (graceful pod delete) after 3
  passes, not after the stuck-down wait: `REACHABLE AGAIN: <key> … restarted
  now to re-register`. The restart has the same gates as the stuck-down
  recovery ([node-down-stuck](#node-down-stuck)): every partition has an
  Active master and the breaker is not tripped. The pod re-registers, goes
  Prepare and catches up.

While the path is cut the operator logs, about every 30 s, `CRITICAL: node
<key> is READY but the OPERATOR cannot connect to it (<n> consecutive probes,
~<s>s) …`.

**The alert.** `flare_operator_nodes_unreachable` counts the Active masters
and slaves with at least one failed probe in a row. A node marked down
(proxy) leaves the count, so with `for: 5m` the alert means a node stayed
unreachable WITHOUT being failed over: typically a master kept for lack of a
promotable successor (or failover paused by the circuit breaker).

**A demoted master that is cut off keeps its old map.** It never receives
the map that demoted it, so clients that still reach it can keep writing to
it until it is restarted — when it answers again (3 passes) or by the
stuck-down recovery (`FLARE_DOWN_RESTART_CYCLES`). Those writes are not on
the new master. Fix the path quickly, or delete that pod (step 5).

1. Establish which side is broken. From the operator pod:
   `kubectl -n <ns> exec deploy/<release>-flare-operator -- sh -c 'timeout 3
   bash -c "</dev/tcp/<pod-ip>/12121" && echo ok'`. Then try the same from a
   different pod in the namespace. If only the operator fails, suspect its
   node's networking or a NetworkPolicy.
2. Check whether the node is actually serving: `printf 'stats\r\n' | nc
   <pod-ip> 12121` from a debug pod, and look at its request rate.
3. Compare what that node believes with what the operator committed:
   `printf 'stats nodes\r\n' | nc <pod-ip> 12121` versus
   `kubectl -n <ns> get cm <cluster>-node-map -o jsonpath='{.data.nodeMap}'`.
   A mismatch confirms it is running on a stale map.
4. Fix the path (CNI, NetworkPolicy, node networking). Once it answers, a
   node that was marked down is restarted automatically (above); one that
   was kept receives the next topology push.
5. If the path cannot be fixed quickly and the node's role is wrong in a way
   that matters (it believes it is master for a partition someone else now
   masters), delete that pod gracefully — it re-registers with a clean view.
   A master that was KEPT is the partition's only master: do not delete it
   unless its data is on another copy or a backup.

## FlareNodeDownStuck (warning) {#node-down-stuck}

A node sits Down while its pod is alive. Down does not clear itself: the
operator only re-seats a node that RE-REGISTERS, and while the committed map
says Down the readiness probe keeps failing (it asks flared for its own
Active state), so only a fresh flared process breaks the loop.

The operator restarts such a pod itself (graceful delete, one per pass, a
Down proxy only), but only when **every partition already has an Active
master** and the circuit breaker is not tripped — deleting a pod on a tmpfs
cluster erases that node's copy, so the gate exists to never destroy the
last one. Log: `STUCK-DOWN RECOVERY: <key> has been Down with its pod present
for <n> ticks …`. When:

- after `FLARE_DOWN_RESTART_CYCLES` passes (default 60, about 5 min at the
  normal 5 s pass; passes run every ~100 ms while a handover is in flight,
  so it can come sooner);
- after 3 passes for a node marked down because the operator could not reach
  it ([node-unreachable](#node-unreachable)) or for a
  [duplicate master claim](#duplicate-master), once it answers the latest
  probe round again (`REACHABLE AGAIN: …`).

This alert firing for 15 min means the gate is holding (or the node is still
unreachable and the restart did not bring it back).

1. Why is the gate closed? `node sync` — is a partition masterless
   ([master-missing](#master-missing)), or is the breaker tripped
   ([circuit-breaker](#circuit-breaker))? Fix that first; the restart then
   happens on its own.
2. If you must act manually, confirm another node holds the partition's data
   (`printf 'stats\r\n' | nc <pod-ip> 12121`, compare `curr_items`) BEFORE
   deleting the Down pod.
3. Never delete both replicas of a partition on a tmpfs cluster.

## A node claims a master the map gives to another node (spec 13) {#duplicate-master}

Every node receives the same node map, so a node that says it is the master
of a partition whose master in the committed map is ANOTHER node runs on a
different map: it missed the push, or it is ahead of the operator. Two
masters of one partition take writes that diverge, so the operator does not
tolerate it.

**What the operator does.** The topology audit reads each node's `stats`
(one node per pass, in turn) and compares its `own_role` / `own_partition`
with the committed map. Only a node that reports a map version OTHER than
the committed one (audit verdict behind or ahead) can conflict.

1. First sighting: `CRITICAL: <key> claims to be a MASTER the committed map
   v<N> gives to another node (reports v<M>); the map is re-sent, and it is
   treated as down if the claim still stands in 15 s`. A node that is behind
   is sent the map again. From then on that node is read every pass.
2. Still claiming after 15 s: `DUPLICATE MASTER: <key> still claims a master
   the committed map gives to another node after 15 s -> treated as down
   (proxy); the map's master is kept`. The node joins the same dead
   detection as an unreachable one ([node-unreachable](#node-unreachable)).
   While its stats cannot be read, the first sighting is kept but nothing is
   decided: the down needs a reading that still shows the claim after 15 s.
3. It is restarted (graceful delete) once it answers the operator's probe,
   after 3 passes, under the stuck-down gates
   ([node-down-stuck](#node-down-stuck)); the new process re-registers and
   gets the current map. `DUPLICATE MASTER: <key> no longer claims a
   conflicting master role` when a later reading agrees.

Nothing is decided while the operator reaches no node (the
[spec 12 guard](#node-unreachable)). A flared that does not report
`own_role` / `own_partition` is never judged. The gauges
`flare_operator_duplicate_master_claims` (pending claims) and
`flare_operator_duplicate_master_down` (nodes down for one, until restarted)
drive the alert `FlareDuplicateMaster` (1 min); the operator log lines are
`claims to be a MASTER` and `DUPLICATE MASTER`. For a node that is ahead the audit also logs
`[TopologyAudit] CRITICAL: recipient <key> reports newer authority … the map
generation is not changed for it (a duplicate master claim is judged
separately, see DUPLICATE MASTER)` — that line is about the generation only;
the duplicate-master check above still applies.

Do:

1. `node sync` and the node's `printf 'stats nodes\r\n' | nc <pod-ip> 12121`:
   which node is the map's master, and which map version does the claimant
   hold?
2. A node that is ahead of the operator points at a competing leader or a
   rewritten map: follow [Topology observation](#topology-observation) step
   4 and keep the evidence.
3. Writes the claimant took while it acted as master are not on the map's
   master. Compare `curr_items` and sample keys before deciding whether
   anything has to be carried over by hand.

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

## A master's flared restarted: its replica rebuilds {#master-restart-rebuild}

Log lines: the master's `node add` re-registers it as `Slave P<n> (Prepare)`,
then `PROMOTION of a LAGGING copy: <master> — a last resort` and, on the
replica, `read source NEEDS REBUILD: history differs`.

When a master's flared container restarts by itself (crash, OOM, a SIGTERM
that did not come from the operator), the operator cannot tell a zombie
from a restart over TCP, so it registers the returning process as a
Prepare slave and leaves the master decision to the next reconcile pass.
That pass re-seats the copy that holds the data, usually the same pod.
Seating a master always starts a new history (source epoch). A replica bound
to the old history therefore rebuilds from the master once.

- **Data**: none is lost. The master kept its copy and is seated again.
- **Cost**: one full rebuild of each replica of that partition, and a short
  window without a master (writes to the partition fail until the re-seat).
- **Expected**: the master's epoch moves by exactly one. Older builds could
  advance it twice while applying one map (`source epoch advanced` twice);
  that was a flared defect, fixed together with L11. It did not cause an
  extra rebuild.
- **Avoid it**: restart flared pods through the node guard
  ([#node-guard](#node-guard)), which hands the master over first.

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
- A first build (proven new or approved) creates the history record
  `<cluster>-history` with `origin first-build`. Only such a record allows the
  first-build exception for a partition that was never recorded
  ([First-build exception](#first-build-exception)).

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

## Storage corruption alerts {#storage-corruption}

Three alerts from flared's own `/metrics`:

| Alert | Fires on | Meaning |
|---|---|---|
| `FlareStorageCorruption` (critical) | `flare_node_rocksdb_corrupted == 1` for 1 min | a RocksDB write returned Corruption, or the periodic checksum check (`VerifyChecksum`) failed; flared latched `rocksdb_corrupted 1` |
| `FlareStorageCorruptionRecurring` (warning) | `increase(flare_node_rocksdb_corruption_detected[1h]) > 0` | new detections in the last hour, also on a pod that has since recovered (the latch is clear again) |
| `FlareReplicationCrcMismatch` (warning) | `increase(flare_node_rocksdb_wal_sync_crc_mismatch[1h]) > 0` | a WAL sync or snapshot-push batch failed its CRC-32 check and was rejected before it was applied |

flared log lines: `STORAGE CORRUPTION detected at <where>: … -> latching
corrupted`, `STORAGE CORRUPTION found by periodic verify: …`, `WAL sync
batch CRC mismatch at LSN … -> aborting sync before apply (transport
corruption; falling back to full dump)`, `snapshot push: WAL tail batch CRC
mismatch …`.

A corrupt copy is never chosen for promotion (the operator's promotion
evidence rejects it: `the copy is flagged corrupted`).

**FlareStorageCorruption on a REPLICA.** On its next reconstruction a
corrupt replica moves its copy aside (`quarantine-…` in the data dir, never
deleted) and reseeds from the master (log `local storage is corrupted ->
moving it aside (quarantine) before reseed`). The fastest trigger is a
graceful `kubectl delete pod <replica>`. If one quarantined copy is already
kept, it stops instead (`rebuild_blocked=quarantine_full`, nothing moved or
deleted): inspect and discard the old quarantine with a
`FlareCopyDiscardApproval`, or follow [replace-corrupt](#replace-corrupt)
Case A.

**FlareStorageCorruption on a MASTER.** Its data may be the last copy and
writes to it fail. Do not wipe it. Confirm a replica is Active and holds the
data (`curr_items`, sample keys), then hand the master over with a graceful
delete through the [node guard](#node-guard) and rebuild the old master as a
replica: [replace-corrupt](#replace-corrupt) Case B. With no healthy replica,
take what a backup holds: Case C.

**FlareStorageCorruptionRecurring.** Repeated detections on one pod point at
its volume or host: move the pod off that node (cordon it, see
[cordon-move](#cordon-move)) or replace the volume.

**FlareReplicationCrcMismatch.** Nothing was written from the bad batch; the
replica falls back to a full dump. Recurrence points at the network between
the two pods or at the source's volume: check which source the replica
follows and whether the mismatches follow one source or one path.

## Backup / Restore

See docs/BACKUP_RESTORE.md for the full procedures (tier-1 checkpoints,
S3 tier-2, single-partition vs multi-partition restore and its caveats).

### FlareBackupStale (warning) {#backup-stale}

The chart's alert `FlareBackupStale` fires when
`time() - flare_node_rocksdb_last_backup_epoch > 172800` (2 days) for 30 min;
flared exports the metric itself on its `/metrics`. Tune the threshold to
twice your backup interval.

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

**Not for this release.** Continuous WAL replication stays **OFF** in this
release (user decision 2026-10-31: it is turned on in the next release).
Leave `replFollowEnabled` unset/false; this section is kept for that later
release and is not an operation to run now.

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

**FlarePodMemoryHigh (warning, >85% for 10m) / FlarePodMemoryCritical
(critical, >95% for 2m).** Both read the pod cgroup slice (`container=""`),
the only series that includes the tmpfs data pages (`kubectl top` misses
them; measure tmpfs with `df`/`du` in the pod). **On a tmpfs cluster treat
an OOM kill as data loss on that node** (a master without a replica can lose
its partition), so act before it: size the limit by the rule above (raise
`cluster.resources.limits.memory`, keep `tmpfs.sizeLimit` within it), or
lower the cache sizes.

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

## Restarting, deleting and upgrading flared pods (node guard) {#node-guard}

Pod replacement is lossless when it goes through the operator:

- **helm upgrade / `kubectl rollout restart`**: the flared StatefulSet uses
  `updateStrategy: OnDelete`, so a template change replaces nothing by
  itself. The operator replaces the pods on an old revision one at a time
  (the highest ordinal first, a master last), and only while every replica is
  caught up. A master is handed over first (ordered handover); its pod is
  deleted only once it is no longer the master. Progress is in the operator log
  (`ROLLING:`; how to follow it: [Upgrading a release](#upgrading)).
  `FLARE_OPERATOR_ROLLING=off` on the operator stops it; then delete pods by
  hand, one at a time, as below.
- **`kubectl delete pod <pod>`** (with its grace period): a replica or a
  proxy is allowed. A master is refused the first time: the refusal starts
  its ordered handover to a caught-up replica (operator log
  `HANDOVER p<N> done`, normally seconds; writes wait briefly, none fail).
  Run the same delete again once it is done — the pod is then a proxy and
  the delete is allowed. The delete never comes before the switch (a delete
  cannot be undone, and the replica could change in between).

**Upgrading from rc68 or older.** A master whose flared predates the
ordered handover (it reports no `proxy_write_in_flight` / `proxy_write_failed`)
cannot be handed over without possible loss. By default the operator does not
replace it: rolling waits (`ROLLING: waiting (master … runs a flared from before
the ordered handover …)`) and the node guard refuses its delete. To accept the
risk for this one upgrade, set `legacyMasterSwitch: true` (operator env
`FLARE_OPERATOR_LEGACY_MASTER_SWITCH=allow`): such a master is then replaced by
the drain's promotion, only while a caught-up replica exists and only after
the operator's startup grace (`FLARE_STARTUP_GRACE_SECONDS`, default 120 s
after it became leader), logged NOT loss-free. Set it back to false once every
pod runs this release. Step by step: [Upgrading a release](#upgrading).

The node-guard webhook (`nodeGuard.enabled`, default true) refuses what
skips that path. The refusal message says why:

| Refused | Why | What to do |
|---|---|---|
| `kubectl delete pod --force --grace-period=0` of a master or a replica | no preStop, no handover: acknowledged writes can be lost | delete without `--force` |
| graceful delete of a master with a caught-up replica | it is handed over first (this refusal starts it) | run the delete again after `HANDOVER p<N> done` |
| delete of a master whose partition has no caught-up replica (Active, Ready, R3 eligible with a complete pod / boot / copy identity, idle, no replica repair pending) | nothing the handover can promote (on tmpfs the data is lost) | wait until the replica has caught up |
| delete of a pod the operator's node map does not know (for example still starting) | it may hold data on its volume | wait until it registered, or use the override |
| delete of a pod whose ordered handover is still completing (the map may already show it as a proxy) | the promote map is not on every pod yet | retry in a few seconds |
| delete of a master when the operator could not list the pods (`the pods could not be read to judge this delete`) | the successor cannot be checked | retry |
| eviction or delete of any flared pod on a cordoned node (HTTP 429) | its [cordon move](#cordon-move) has not released it (waiting for its turn, blocked, or in progress) | wait (`kubectl drain` retries), see `status.nodeMoves` |
| any data-pod delete or scale-down right after the operator started or a new leader took over | the operator has not read the cluster yet | retry after a few seconds |
| `kubectl scale` / a StatefulSet edit removing ordinals that hold data | the removed pods are masters or replicas (or not in the map) | reduce partitions or replicas in the FlareCluster spec (the operator moves the data first) |
| `kubectl delete statefulset <name>-nodes` (cascading, the default) | every pod goes at once, masters with no handover (on tmpfs their data) | `--cascade=orphan` (the pods stay and each delete is judged), or the teardown below |

**Who is never refused.** The operator's own service account,
`system:kube-controller-manager`, and only these kube-system service
accounts of the controller manager: `namespace-controller`,
`generic-garbage-collector`, `statefulset-controller`,
`pod-garbage-collector`, `node-controller`. The kubelet only when it confirms
the removal of a pod already terminating on its node. Every other requester
goes through the guard, including other kube-system accounts such as the
cluster-autoscaler or a descheduler: their evictions are judged like
`kubectl drain` (handover, cordon move).

**What the webhook sees.** Two pod webhooks, both limited to the release's
namespace:

- `pods.node-guard.flare.gree.net` (pods DELETE) sees every pod of the
  namespace except the operator's own (`objectSelector` on
  `app.kubernetes.io/name` NotIn the chart name). The operator judges only
  this cluster's flared pods, told apart by `spec.subdomain`, so removing a
  flared pod's labels does not hide its delete; other pods are allowed.
- `evictions.node-guard.flare.gree.net` (pods/eviction CREATE) has no
  selector (an Eviction carries none of the pod's labels), so it sees every
  eviction in the namespace. The operator reads the pod and judges only this
  cluster's flared pods, told apart by `spec.subdomain` (`<name>-nodes`);
  other pods' evictions are allowed. A pod it cannot read is held (429).

A third webhook judges UPDATE / DELETE of StatefulSets in the namespace
(only `<name>-nodes` is gated).

### Tearing the whole cluster down

Deleting the FlareCluster or the namespace removes everything through
Kubernetes' garbage collector, which the guard does not refuse. To delete
only the StatefulSet with its pods (for example before `helm uninstall`),
name it by UID:

```sh
UID=$(kubectl get statefulset <name>-nodes -n <ns> -o jsonpath='{.metadata.uid}')
kubectl annotate statefulset <name>-nodes -n <ns> --overwrite flare.gree.net/delete-override=$UID
```

### Break-glass: deleting a pod anyway {#node-guard-break-glass}

Use this only when you accept losing that pod's unreplicated writes (for
example the pod is stuck and its data is already gone). It is recorded: the
operator logs `NODE GUARD: allowed DELETE pods <pod> (uid …) by <user>:
flare.gree.net/delete-override names this pod (uid …): allowed as an
explicit exception`. The override is checked before the cordon move, so it
works for an eviction too.

```sh
UID=$(kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.uid}')
kubectl annotate pod <pod> -n <ns> --overwrite flare.gree.net/delete-override=$UID
kubectl delete pod <pod> -n <ns> --force --grace-period=0
```

The annotation names one pod by UID: the pod the StatefulSet creates in its
place has a new UID and is guarded again. `kubectl delete --force` may print
an error naming that new pod after the old one is already gone; check with
`kubectl get pod <pod> -o jsonpath='{.metadata.uid}'`.

### The operator is down (the webhook fails closed) {#node-guard-operator-down}

`failurePolicy: Fail`: with no operator leader answering, every call to the
webhook fails, so in the release's namespace these are refused:

- the DELETE of every pod but the operator's own (flared pods, backup Job
  pods, debug pods): `failed calling webhook "pods.node-guard.flare.gree.net"`;
- **every eviction of every pod**, not only flared ones (the operator's own
  pods, backup Jobs, anything else in the namespace): `kubectl drain` keeps
  failing with `failed calling webhook "evictions.node-guard.flare.gree.net"`;
- every StatefulSet UPDATE and DELETE (`"statefulsets.node-guard.flare.gree.net"`),
  which also makes a `helm upgrade` that touches the flared StatefulSet fail.

A `kubectl delete pod` of the operator's own pod is not affected.
The override annotation does not help here (nothing answers to read it).
Bring the operator back first. If that is not possible, turn the guard off
and back on after the work:

```sh
helm upgrade <release> ... --set nodeGuard.enabled=false \
  --set nodeReplacement.enabled=false      # removes the webhook (the chart refuses
                                           # nodeReplacement without the guard)
# ... the operation ...
helm upgrade <release> ... --set nodeGuard.enabled=true --set nodeReplacement.enabled=true
```

Without the guard nothing stops a force delete of a master: do one pod at a
time and only graceful deletes.

## Cordon (`kubectl cordon` / `drain`) moves the pods off a node {#cordon-move}

Design: `flare-ci-inputs/decisions/NODE-OPS-NOSTOP-IMPLEMENTATION-PLAN-2026-10-26.md`
section C. State machine: `flare_operator/FlareOperator/StateMachine/NodeMove.lean`.
Chart values: `nodeReplacement.*` (needs `nodeGuard.enabled`; the chart refuses
`nodeReplacement.enabled` without it). `FLARE_NODE_REPLACEMENT=off` on the
operator turns the whole feature off.

**This release supports the cordon move on tmpfs clusters only** (user
decision 2026-11-01). It is verified there (E2E cordon-master / cordon-replica:
errors 0, missing 0). On a PVC cluster it is NOT verified: with node-local
volumes (local PV, local-path) the recreated pod cannot leave the cordoned
node, stays Pending and the move stays `resyncing` (no data lost; one copy
fewer and the next moves wait until the uncordon); with network storage the
recreated pod comes back with its old data, a path not tested yet. On a PVC
cluster set `nodeReplacement.enabled: false`: drains then go through the node
guard's handover only, as before.

**Check the copy count first.** The chart defaults are `cluster.replicas: 3`
(a master and two replicas per partition) and `nodeReplacement.minCopies: 3`
with `nodeReplacement.enabled: true`: a move keeps a replica besides the
master. A cluster that sets fewer copies explicitly (pf-dev: 1 master + 1
replica) is below `nodeReplacement.minCopies`: no master or replica can be
moved, every such move is blocked, the guard keeps refusing those evictions,
and `kubectl drain` waits until it times out. For such a cluster choose one:

- `cluster.replicas: 3` (or more): moves run with two copies left; or
- `nodeReplacement.minCopies: 2`: 2-copy partitions move, with the master
  as the only copy while the moved replica is rebuilt — an explicit,
  accepted risk (if the master fails meanwhile there is no replica to
  promote; on tmpfs its data is lost); or
- `nodeReplacement.enabled: false`: no cordon move; drains go through the
  node guard's older rules (graceful delete + handover).

**What happens.** A Node gets `spec.unschedulable=true`. For each flared pod on
it, **one pod at a time** (cluster-wide, also with two cordoned nodes), the
operator records a move in `status.nodeMoves` and walks it through:

| phase | meaning |
|---|---|
| `pending` | started; a master asks the ordered handover (demote → drain → promote) for a successor on an uncordoned node, a replica is demoted to a proxy |
| `handingOver` | (master only) the handover runs |
| `proxied` | the pod is a proxy; the operator removes its `flare.gree.net/serving` label |
| `unserved` | waiting until (a) the client Service (`<name>-nodes-external`, which selects the label) no longer lists the pod in its EndpointSlices, (b) the pod's `client_requests` (data requests) did not grow for 10 s (`quietSeconds`; an older flared without it: `total_connections` minus the operator's own stats connections), (c) `curr_connections` is 0 (minus the operator's own one), and flared's own `own_role` is `proxy`. The quiet baseline is bound to the flared process (`reconstruction_boot_id`): a restarted flared, or a counter that went down, starts the 10 s again |
| `released` | written **only by the operator**. The node guard now lets an eviction or delete of this pod through. If nothing evicts within 60 s the operator deletes it (UID precondition) |
| `deleted` | the old pod is gone |
| `resyncing` | the StatefulSet recreated it on another node; the operator seats it as a replica; when Ready, Active and synced (R3 eligible) as a Slave it gets the serving label back — never while it is Terminating. No timeout: a pod that never becomes such a Slave keeps the move here, and the next move does not start |
| `done` | finished |
| `cancelled` | the node was uncordoned before `released` (see below) |

`kubectl get flarecluster <name> -o jsonpath='{.status.nodeMoves}'` shows the
record; the operator log lines start with `NODE MOVE`; Events carry
`FlareCordonMoveStarted / Blocked / Held / Released / Cancelled / Done`, and the
Warning `FlareCordonMoveOnCordonedCopy` (below).

**Not enough copies (`FlareCordonMoveBlocked`).** The move starts only if the
partition would keep enough *real* copies. A real copy is on another node
than the pod being moved (a cordoned one counts too), Active in the map with its pod Ready, has the same
`rocksdb_master_id` and `rocksdb_source_epoch` as the master, is not
quarantined and not reported `rocksdb_copy_identity_consistent 0`, has no
open replica repair and no new drop/failed write from the master since the
operator saw it. (A copy, or a master, that does not report its master id
and source epoch is not a real copy: a missing value never matches.) The
copy being moved counts toward
`nodeReplacement.minCopies` (default 3: master + 2 replicas → 2 real copies
remain); at least one other real copy must always remain. If fewer would
remain the move does **not** start, the pod is listed in
`status.nodeMoves.blocked` with the reason, an Event fires, and the eviction
of that pod stays refused (HTTP 429, `kubectl drain` waits and retries). Fix
it by adding a copy (`replicas`), waiting for a repair/rebuild to finish, or
uncordoning; setting `nodeReplacement.minCopies: 2` moves 2-copy partitions
too, with the master alone while the replica is away — an explicit, accepted
risk.

- The alert `FlareCordonMoveBlocked` is raised only while NO move is
  running; a blocked pod behind a running move shows in
  `status.nodeMoves.blocked` only.
- A copy on ANOTHER cordoned node counts: the node guard holds that pod's
  eviction until its own move is released, and one move runs at a time, so it
  stays while this one is away. When every copy left during a move is on
  cordoned nodes, the move still starts, with the log line `WARNING: NODE
  MOVE <pod>: … other copies are only on cordoned node(s)` and the Warning
  Event `FlareCordonMoveOnCordonedCopy`. Do not let those nodes be removed
  (forcibly, outside the API) before the move is done: uncordon one or add a
  copy if they must go.
- Also blocked: a pod that is not Ready, is Terminating, is not in the map
  or has no serving label (`the pod is not Ready or is terminating`), and a
  master with no caught-up replica on an uncordoned node (`no caught-up
  replica on an uncordoned node to take the master over`). A Down flared pod
  on a cordoned node therefore stops the drain until it is Ready again or is
  removed with the [break-glass](#cordon-move-break-glass) override.

**Held (`FlareCordonMoveHeld`).** Either the client Service still reached the
pod 120 s (`drainWaitSeconds`) after the label was removed (clients keep
connecting through a load balancer that has not dropped the pod, or hold
connections open), or the handover aborted three times. The pod stays a
proxy / master, **nothing is deleted**, the reason is in
`status.nodeMoves.moves[].reason`. It releases by itself if the evidence turns
up later. Look at `kubectl get endpointslices -l kubernetes.io/service-name=<name>-nodes-external`,
the load balancer's targets, and the pod's `stats` (`client_requests`,
`curr_connections`). Flared closing a client connection after a response is
**not implemented yet** (L9): a client that never reconnects keeps the pod
held; a later change adds it.

**Uncordon.** The operator writes `cancelled` (generation + 1) **first** and
puts the serving label back **after** that write succeeded, so an eviction
that races the uncordon either sees `released` (the move completes) or does
not see it at all. After `released` an uncordon does **not** cancel the move:
the guard now holds evictions of the pod (its node is no longer cordoned),
and the operator deletes the pod itself `evictWaitSeconds` (60 s) after the
release; the recreated pod may come back to the uncordoned node. While
a master's handover runs it is not interrupted; the move ends right after.

**Eviction/delete rules** (node guard: a pod DELETE, or an eviction judged as
that pod's delete). A pod with a move, or any flared pod (a proxy too) on a
cordoned node without one, is refused with 429 until its move is `released`
**and** the pod UID matches, it has no serving label, and its node is still
cordoned. The webhook
writes only `admitted` (move id, generation, AdmissionReview uid) as a
compare-and-swap on `status.nodeMoves` just before it allows, only as the
lease holder with at least 5 s of lease left, and re-checks the lease after
the write; a dry run writes and allows nothing. If the write fails the
request is refused and retried by `drain`.

### Break-glass: evicting or deleting a pod before its move is released {#cordon-move-break-glass}

Accepting that clients may be dropped and, for a master/replica, that
unreplicated writes can be lost: use the audited override of the node guard
(see [Break-glass: deleting a pod anyway](#node-guard-break-glass)):

```sh
UID=$(kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.uid}')
kubectl annotate pod <pod> -n <ns> --overwrite flare.gree.net/delete-override=$UID
kubectl drain <node> --delete-emptydir-data --ignore-daemonsets   # or kubectl delete pod
```

The override names one pod by UID and is logged by the operator (`NODE GUARD:
allowed ... delete-override names this pod`); it works with the Eviction API,
so the drain procedure does not change. A move for that pod is then cancelled
or finished by the operator as the pod disappears. To stop the whole feature
instead: `nodeReplacement.enabled=false` (or `FLARE_NODE_REPLACEMENT=off`) —
the node guard's older rules (graceful delete + handover) apply again, and
the Service selector loses the serving label requirement.

### Limits of this step

- Flared does not yet close client connections after a response (L9); the
  move relies on clients or the load balancer dropping the pod.
- `curr_connections` counts every open connection to the pod; the operator
  subtracts only its own one. Any other connection still open (a client's,
  or another flared node's) keeps the move `unserved` and, after
  `drainWaitSeconds`, held.
- A pod on a node-local PV cannot be recreated elsewhere: use tmpfs or
  network storage.

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

`target.replicas` (copies per partition) defaults to **3**, like
`cluster.replicas`. Keep it at least `nodeReplacement.minCopies` (default 3):
with fewer copies every [cordon move](#cordon-move) of the target cluster is
blocked.

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

## Topology observation {#topology-observation}

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

The node map now carries `transition=<id>` lines (rc67 and rc68 read them;
for a rollback to those see [Rolling a release back](#rollback)). An older
operator's strict startup validation rejects them (it halts with "node line does not parse").
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

It then records the history from that copy and promotes as usual.

A partition of a first build that was never recorded has its own rule:
[First-build exception](#first-build-exception).

Anything else is HELD on purpose: choosing between histories decides which data survives, and
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

### First-build exception {#first-build-exception}

A partition of a record created by a first build (`origin first-build` in `<cluster>-history`) that
has no record line and no intent yet — for example the first master's flared
restarted before its history was recorded and came back as a replica — has
nothing to choose between when every copy is empty. The operator seats its
master as a first build's and records the history from it, only when every
copy of the partition (the copies in the node map) reads EMPTY both in this
pass's evidence and again at the commit, with the same pod UID, boot id and
copy id. Log: `promotion of <key>: partition N of this first build has no
recorded history and every copy reads empty … — seated as a first build's
master`. If a copy is not empty at the commit, or its pod / boot / copy
changed, the exception is refused and nothing from that pass is committed:
`CRITICAL: PROMOTION ABORTED for <key>: the first build exception for
partition N is REJECTED …` (the line lists each copy's pass and commit
reading). The next pass decides again; a refusal that repeats means a copy
holds data or keeps restarting — read the listed copies before anything else.
A copy that is not in the node map is not part of this check.

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

## Known limits (do not be surprised by)

- Selective network partition (pod alive, TCP to operator blocked): since
  spec 12 the node is marked down after 3 failed probes, a master only when
  a reachable promotable successor exists, and nothing happens while no node
  is reachable ([node-unreachable](#node-unreachable)). The probe is a TCP
  connect only: a wedged flared that still accepts connections is not failed
  over by it. A demoted master that is cut off keeps its old map and can
  take client writes until it is restarted. When the operator reaches only
  some nodes because of its OWN partial network fault, healthy masters can be
  failed over (the guard covers only "no node reachable").
- A client write sent with `noreply` is forwarded to the other copies as
  `noreply` too (fire-and-forget). If the forwarding connection is reset,
  such writes can be lost **without** being counted in
  `proxy_write_dropped` (FlareProxyWriteDropped stays quiet). Writes that
  wait for their reply (`STORED` / `DELETED`) are not affected this way.
- Multi-partition restore requires manual partition-affinity verification
  (BACKUP_RESTORE.md Case C) until partition pinning is implemented.
- Config changes: hot-reloadable options land within ~2min (kubelet
  propagation + verified re-SIGHUP); WAL-retention/cache options need a pod
  restart — the operator logs which is which.
