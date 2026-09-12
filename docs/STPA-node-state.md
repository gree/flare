# STPA: node state transitions (when does a node go Down?)

Hazard analysis of the operator↔flared control loop, focused on the question
that keeps coming up in incidents: **when does a node leave the serving set,
who decides, and on what evidence?** Written after the 2026-09-07 finding
that a segfaulted flared was never detected at all.

Method: STAMP/STPA — losses, hazards, control structure, then Unsafe Control
Actions (UCA) and the scenarios that produce them.

## Evidence and status

Control status is maintained in [safety-evidence.json](safety-evidence.json).
The generated table below is the only status inventory in this document.
Implementation and verification are separate: code existence, a comment, a
test definition, or a passing library build does not establish end-to-end safety.
All initial entries are unverified pending archived, scenario-specific evidence.
See [SAFETY-TODO.md](SAFETY-TODO.md) for merge gates and the review workflow.

Each EV record includes an SC safety constraint, stable UCA links, assumptions,
residual risks, implementation symbols and production call paths, verification
procedures and immutable execution evidence. A verified control only supports
its bounded claim; it does not close every linked hazard. Alerts describe
detection, not prevention, and depend on deployment enablement and routing.

<!-- safety-evidence:begin -->

<!-- Generated from safety-evidence.json; do not edit this table. -->
| Evidence / constraint | Bounded claim | Hazards / UCA | Implementation | Verification | Code / candidate check |
|---|---|---|---|---|---|
| <a id="ev-01"></a>EV-01 / SC-01 | Only the current leader may issue topology changes; recipients must reject obsolete authority. | H6, H4, UCA-14, UCA-15, UCA-16, UCA-08 | partial | unverified | [code](../flare_operator/FlareOperator/Main.lean), [check](../flare_operator/FlareOperator/E2E/Tests/TopologyAuthority.lean) |
| <a id="ev-02"></a>EV-02 / SC-02 | mergeClusterState commits at most one Master per partition in its node map. | H6, UCA-08, UCA-14 | implemented | unverified | [code](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean), [check](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean) |
| <a id="ev-03"></a>EV-03 / SC-03 | A replica with missed writes remains repair-pending until reconstruction completes and missing data is recovered. | H3, H2, UCA-02 | implemented | unverified | [code](../flare_operator/FlareOperator/Main.lean), [check](../flare_operator/FlareOperator/E2E/Tests/ReplicaRepair.lean) |
| <a id="ev-04"></a>EV-04 / SC-04 | Normal promotion and Prepare activation require a completed usable copy associated with the current source. | H2, H4, UCA-10 | partial | unverified | [code](../flare_operator/FlareOperator/StateMachine/SyncEvidence.lean), [check](../flare_operator/FlareOperator/E2E/Tests/PrepareEvidence.lean) |
| <a id="ev-05"></a>EV-05 / SC-05 | Delete only a revalidated target when independent current evidence supports the surviving copy. | H5, H2, UCA-07, UCA-11, UCA-12, UCA-13 | partial | unverified | [code](../flare_operator/FlareOperator/StateMachine/StatsObservation.lean), [check](../flare_operator/FlareOperator/StateMachine/StatsObservation.lean) |
| <a id="ev-06"></a>EV-06 / SC-06 | Refill missing masters under an explicit emergency policy, with partial-copy promotion distinguished from normal successor promotion. | H1, H2, H5, UCA-04, UCA-07, UCA-09, UCA-10 | partial | unverified | [code](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean), [check](../flare_operator/FlareOperator/E2E/Tests/PvcDataSurvival.lean) |
| <a id="ev-07"></a>EV-07 / SC-07 | Use Pod existence/readiness streaks with guards, retaining an unhealthy lone master rather than stripping its assignment. | H1, H4, H5, UCA-01, UCA-03, UCA-05, UCA-12 | partial | unverified | [code](../flare_operator/FlareOperator/Main.lean), [check](../flare_operator/FlareOperator/E2E/Tests/Failover.lean) |
| <a id="ev-08"></a>EV-08 / SC-08 | The pure drain transform retains a master assignment if there is no Active slave successor. | H1, H5, UCA-04, UCA-05 | implemented | unverified | [code](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean), [check](../flare_operator/FlareOperator/E2E/Tests/TerminatingPodHandling.lean) |
| <a id="ev-09"></a>EV-09 / SC-09 | Circuit-breaker policy pauses mass failover; configured recovery refill is a separate path. | H1, H5, UCA-03 | implemented | unverified | [code](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean), [check](../flare_operator/FlareOperator/E2E/Tests/CircuitBreaker.lean) |
| <a id="ev-10"></a>EV-10 / SC-10 | Restart a stuck Proxy/Down only when current safety evidence permits deleting its copy. | H4, H5, UCA-06, UCA-11 | partial | unverified | [code](../flare_operator/FlareOperator/Main.lean), [check](../flare_operator/FlareOperator/E2E/Tests/TerminatingPodHandling.lean) |
| <a id="ev-11"></a>EV-11 / SC-11 | Expose masterless, unhealthy, unreachable, drain-blocked and resync-failure signals; reachability loss alone does not cause failover. | H1, H3, H4, H5, UCA-01, UCA-02, UCA-06, UCA-09, UCA-17 | partial | unverified | [code](../flare_operator/FlareOperator/Main.lean), [check](../flare_operator/FlareOperator/E2E/Tests/NativeMetrics.lean) |
| <a id="ev-12"></a>EV-12 / SC-12 | Count comparison detects some replica divergence; content equality requires additional verification. | H2, H3, UCA-02 | partial | unverified | [code](../flare_operator/FlareOperator/Main.lean), [check](../flare_operator/FlareOperator/E2E/Tests/ReadBalance.lean) |
| <a id="ev-13"></a>EV-13 / SC-13 | A future replication design must specify what acknowledged writes survive and how replicas catch up after interruption. | H2, H3, H5, UCA-02 | gap | unverified | [code](../src/lib/queue_proxy_write.cc), [check](../flare_operator/FlareOperator/E2E/Tests/StrictDurability.lean) |
| <a id="ev-14"></a>EV-14 / SC-14 | Endpoint readiness should reflect serving eligibility without preventing StatefulSet recovery. | H4, H1, UCA-01, UCA-18 | partial | unverified | [code](../helm/flare-operator/templates/flare-cluster.yaml), [check](../flare_operator/FlareOperator/E2E/Tests/TerminatingPodHandling.lean) |
| <a id="ev-15"></a>EV-15 / SC-15 | Operational comparison should identify current source and each replica rather than infer from cluster-wide counts. | H3, H4, UCA-02 | gap | unverified | [code](../src/lib/metrics_formatter.cc), [check](../flare_operator/FlareOperator/E2E/Tests/NativeMetrics.lean) |

<!-- safety-evidence:end -->

## 1. Losses

| ID | Loss |
|---|---|
| L1 | Durable data loss (keys gone from every copy) |
| L2 | Incorrect read (client gets a stale value, or a miss for a key that exists) |
| L3 | Write unavailability (a partition takes no writes) |
| L4 | Read unavailability |
| L5 | Operator/on-call cannot tell whether the cluster is healthy |

## 2. Hazards

| ID | Hazard | Leads to | Detection | Control and limitation | Evidence |
|---|---|---|---|---|---|
| H1 | A partition has no Active master | L3 | Per-partition masterless gauge; a kept unhealthy master needs the unhealthy signal instead. | Failover/refill exists; autoResetEnabled=false can park recovery. | [EV-06](#ev-06), [EV-07](#ev-07), [EV-11](#ev-11) |
| H2 | An Active master holds less data than a replica | L2, L1 | Zero-count and count-delta probes only; missing stats currently become zero. | Active-successor checks are not independent sync evidence; Prepare repair and emergency refill have exceptions. | [EV-04](#ev-04), [EV-05](#ev-05), [EV-06](#ev-06), [EV-12](#ev-12) |
| H3 | A replica diverges without reliable repair | L5, L1, L2 | Destination drop counters and one-slave count comparison. | Automatic resync is attempted, but intermediate role delivery and pending-work retention are defective (SAF-02/05). | [EV-03](#ev-03), [EV-11](#ev-11), [EV-12](#ev-12), [EV-13](#ev-13), [EV-15](#ev-15) |
| H4 | An unfit node remains in the serving set | L2, L4 | Readiness, unhealthy and operator reachability signals. | Read balance follows topology; limbo readiness and headless access leave serving gaps. | [EV-04](#ev-04), [EV-07](#ev-07), [EV-10](#ev-10), [EV-11](#ev-11), [EV-14](#ev-14) |
| H5 | The last usable copy is destroyed | L1 | Drain-no-successor signal covers one scenario. | Active-master/breaker gates exist but stale snapshots and unknown-as-zero stats can invalidate deletion decisions. | [EV-05](#ev-05), [EV-06](#ev-06), [EV-08](#ev-08), [EV-09](#ev-09), [EV-10](#ev-10) |
| H6 | Two processes act as master for one partition | L1, L2 | No archived distributed-writer exclusion evidence. | The committed-map count proof is narrower than this hazard. Unfenced FSM broadcasts and partial delivery remain. | [EV-01](#ev-01), [EV-02](#ev-02) |

Note for tmpfs clusters: a pod restart is equivalent to erasing that node's
copy, so H5 is reachable by pod deletion alone.

## 3. Control structure

```
        CRD (FlareCluster spec)                 human / ArgoCD
                 |                                    |
                 v                                    v
   +-------------------------------------------------------------+
   |  flare-operator  (leader-elected FSM, 5s tick)              |
   |  control actions:                                           |
   |    A1 node sync broadcast (role / state / partition/balance)|
   |    A2 delete pod                                            |
   |    A3 write extra.conf + SIGHUP                             |
   |    A4 patch <cluster>-<p> Service selector (master pin)     |
   +-------------------------------------------------------------+
        ^ feedback                              | A1..A4
        |                                        v
   F1 pod list (existence)              +--------------------+
   F2 pod Ready condition               |  flared nodes      |
   F3 `node add` registration (TCP)     |  (data plane)      |
   F4 `node state` report (Prepare→Active) +------------------+
   F5 stats probes (curr_items, LSN)          ^        |
   F6 CRD spec                                |        v
                                         kubelet    clients
                                    (liveness/readiness,   (via LB)
                                     container restart)
```

Second controller worth naming explicitly: **kubelet**. It restarts a
container (liveness: tcpSocket 12121, 5s × 6 ≈ 30s) and the endpoint
controller removes a NotReady pod from the client LB (readiness: 5s × 3,
4s timeout ≈ 15–27s). The operator and kubelet act on the same node with no
coordination between them — several scenarios below come from that.

Readiness is **circular by construction**: the probe asks flared for its own
`state active`, and flared's state came from the operator's last broadcast.
So readiness can report "the operator's instruction did not take effect", but
it can never report "flared is serving the wrong data".

## 4. When does a node become Down?

| # | Trigger | Detector | Condition | Action | How it leaves Down | Evidence / limitation |
|---|---|---|---|---|---|---|
| D1 | Pod object gone (delete, evict, reschedule) | operator `detectDeadNodesPure` | key absent from F1, role≠Proxy, state∉{Down,Prepare} | demote to Proxy/Down/partition −1, promote an Active slave if one is found | new pod registers (F3) → Prepare → catch up | [EV-06](#ev-06), [EV-07](#ev-07) |
| D2 | Pod present but not serving (segfault, hang, wedge) | operator, **rc59** | F2 NotReady for `FLARE_UNREADY_DEAD_CYCLES` ticks (default 6 ≈ 30s) on top of kubelet's 3 failures | same as D1 — **except** a master with no promotable successor, which is KEPT as master (`unhealthyMastersKept`) and only logged CRITICAL | container restart (kubelet liveness, or D6) → re-register | [EV-07](#ev-07) |
| D3 | Repeated resync failure | flared itself | failure streak ≥ `rocksdb-resync-failure-threshold` | flared asks the index to mark it down (`request_down_node`) | human, or restart | [EV-11](#ev-11) — alert only; request_down_node has no flarei controller in flared |
| D4 | Graceful drain, no successor | operator drain guard | Terminating master, no promotable slave | **NOT demoted** — stays master to the end; CRITICAL alert | pod dies; partition is masterless until a copy returns | [EV-08](#ev-08) |
| D5 | Mass failure | operator circuit breaker | ≥ `tripThresholdPercent` of Active nodes dead at once | failover **paused**: no Down transitions | breaker clears when the fraction drops | [EV-09](#ev-09) |
| D6 | Stuck Down | operator, **rc59** | state Down + role Proxy + pod present for `FLARE_DOWN_RESTART_CYCLES` ticks (default 60 ≈ 5 min), every partition has an Active master, breaker not tripped | graceful pod delete (one per tick) | re-registration after restart | [EV-05](#ev-05), [EV-10](#ev-10) |

Invariant worth remembering: **Down never clears itself.** `assignProxiesPure`
skips Down nodes, and readiness stays failed while the map says Down, so the
only exit is a fresh flared process re-registering. D6 exists because D2
introduced a new way in.

### Why D2 does not demote a lone master

Demoting a master that has no promotable successor achieves nothing — there
is nobody to promote — while it actively hurts: the partition is declared
masterless sooner, and the node loses the partition assignment that the
rejoin path keys off (`old.partition >= 0` in `Reconciler.lean`), so a
process that is very likely back within seconds takes the fresh-registration
route instead of the clean rejoin. Keeping its assignment avoids an earlier masterless transition, but
NotReady only excludes ordinary client endpoints; headless access and stale
peer topology remain risks (EV-07/14). This is the same decision
the drain guard makes for a Terminating master
(`handleDrainWithPromotionSingleKey` demotes ONLY together with a successful
promotion). A vanished pod (D1) is different — nothing is coming back under
that entry — and still fails over.

Consequence for alerting: the partition serves nothing but still *has* a
master in the map, so `FlareMasterMissing` does NOT fire. The signal is
`FlareNodeUnhealthy` (critical) plus the CRITICAL log line naming the node.

### R1 — recovery without ever going Down

Not every failure produces a Down transition, and the most common one does
not. When a container restarts, flared re-registers over TCP (F3) and the
rejoin branch in `Reconciler.lean` puts the returning node back as
**Slave/Prepare** with `lastMasterOf` stamped — deliberately never straight
back to master, because on tmpfs it returns empty. Its partition is then
masterless, so `promoteMasterlessPartitions` attempts refill on
the next tick. The fallback may crown an unproven or partial Prepare copy;
nonzero key count is not completion evidence (EV-06). This path
is ~5–10s, faster than D2, and it is why the 2026-09-07 segfault recovered
even though nothing detected it.

## 4b. Failure patterns → which detector fires

| Pattern | What K8s does | Signal the operator sees | Path | Latency | Evidence / limitation |
|---|---|---|---|---|---|
| Process exits (segfault, panic) and restarts promptly | container restarts, pod keeps its name and IP | `node add` re-registration (F3) | **R1** — no Down at all | ~5–10s | [EV-06](#ev-06), [EV-07](#ev-07) |
| Same, but CrashLoopBackOff keeps it down | backoff grows, pod stays NotReady | Ready=False (F2) | **D2** | kubelet ~15s + operator ~30s ≈ 45s | [EV-07](#ev-07) |
| OOMKill, single | container restarts (exit 137) | as above | **R1** | ~5–10s | [EV-06](#ev-06), [EV-07](#ev-07) |
| OOMKill, repeating | CrashLoopBackOff | Ready=False | **D2** | ~45s | [EV-07](#ev-07) |
| flared hangs but the port still accepts | tcpSocket liveness **passes** | readiness exec times out → Ready=False | **D2** | ~45s (liveness cannot see this) | [EV-07](#ev-07) |
| Pod deleted / evicted / rescheduled | pod object disappears | key absent from the pod list (F1) | **D1** | 1 tick | [EV-07](#ev-07) |
| Graceful delete with preStop | Terminating, still Ready | deletionTimestamp | **D4** drain (demote + promote inside the window) | 1 tick | [EV-08](#ev-08) |
| Worker node unreachable (kubelet dead, VM hung) | node Ready→Unknown after the monitor grace period, then the node controller marks its pods NotReady; eviction adds a deletionTimestamp later (default 5 min) | Ready=False, then Terminating | **D2**, later **D4** | ≈ node grace + 30s (before rc59: only the 5-min eviction) | [EV-07](#ev-07) |
| Node object deleted / VM gone | pods garbage-collected | key absent from the pod list | **D1** | 1 tick | [EV-07](#ev-07) |
| Network partition: pod alive and Ready, operator cannot reach it | nothing — kubelet is local and keeps reporting Ready | operator TCP probe failures | Reachability probe | ~30s sampling | [EV-01](#ev-01), [EV-11](#ev-11) — reachability alert only |
| flared alive and Ready but serving diverged data | nothing | none | **NOT DETECTED** (G2) | — | [EV-12](#ev-12) — counts only |

Terminating pods are excluded from the D2 population on purpose
(`!p.terminating` in the pod scan): a draining pod belongs to D4, and on a
lost node it can stay Terminating indefinitely, so D6 skips it too rather
than re-issuing a delete that can never complete.

The node-failure timings above are kube-controller-manager settings
(`node-monitor-grace-period`, the unreachable toleration) on a managed
control plane — we do not own them, so treat the numbers as the documented
defaults rather than as measured on this cluster.

The operator collects `PodInfo.nodeName` but does not use it: it cannot
currently tell "one process died" from "every pod on node X went unhealthy
at once". Correlating by node would make the second case identifiable
(and is the natural place to be more conservative about failing over).

## 5. Unsafe Control Actions

A1a = Down/failover; A1b = promotion; A1c = topology broadcast;
A2 = Pod deletion; A4 = Service/endpoint membership. Stable UCA IDs map
to safety constraints in the evidence register; the listed controls are
not assertions that the hazards have been eliminated.

| ID | Action | Timing | Unsafe control action | Hazards | Controls |
|---|---|---|---|---|---|
| UCA-01 | A1a | Not provided | A non-serving node stays Active | H1, H3, H4 | [EV-07](#ev-07), [EV-11](#ev-11) |
| UCA-02 | A1a | Not provided | A divergent replica remains eligible without repair | H2, H3 | [EV-03](#ev-03), [EV-12](#ev-12), [EV-13](#ev-13), [EV-15](#ev-15) |
| UCA-03 | A1a | Provided | Healthy copies are demoted on false/correlated feedback | H5 | [EV-07](#ev-07), [EV-09](#ev-09) |
| UCA-04 | A1a | Wrong order | Master demoted before a usable successor exists | H1, H2, H5 | [EV-06](#ev-06), [EV-08](#ev-08) |
| UCA-05 | A1a | Provided | Lone unhealthy master loses its assignment without a successor | H1 | [EV-07](#ev-07), [EV-08](#ev-08) |
| UCA-06 | A1a | Too long | Live node left Down indefinitely | H4, H5 | [EV-10](#ev-10), [EV-11](#ev-11) |
| UCA-07 | A1b | Provided | Empty or stale node crowned master | H2, H5 | [EV-05](#ev-05), [EV-06](#ev-06) |
| UCA-08 | A1b | Provided | Multiple processes serve as master | H6 | [EV-01](#ev-01), [EV-02](#ev-02) |
| UCA-09 | A1b | Not provided | Masterless partition never refilled | H1 | [EV-06](#ev-06), [EV-11](#ev-11) |
| UCA-10 | A1b | Wrong timing | Replica activated/promoted before completing synchronization | H2, H4 | [EV-04](#ev-04), [EV-06](#ev-06) |
| UCA-11 | A2 | Provided | Deleting the last usable copy | H5 | [EV-05](#ev-05), [EV-10](#ev-10) |
| UCA-12 | A2 | Wrong timing | Deleting during reconstruction or repeatedly while terminating | H4, H5 | [EV-05](#ev-05), [EV-07](#ev-07) |
| UCA-13 | A2 | Provided | Force deletion bypasses evidence and drain conditions | H5 | [EV-05](#ev-05) |
| UCA-14 | A1c | Not provided | Topology application lost or never retried | H1, H2, H4 | [EV-01](#ev-01), [EV-02](#ev-02) |
| UCA-15 | A1c | Too late | Delayed topology arrives after newer authority/assignment | H4, H6 | [EV-01](#ev-01) |
| UCA-16 | A1c | Provided | Deposed leader issues topology commands | H6 | [EV-01](#ev-01) |
| UCA-17 | A1a | Not provided | Repeated resync failures never remove an unsafe replica | H3, H4 | [EV-11](#ev-11) |
| UCA-18 | A4 | Provided | Endpoint membership advertises an unserving node | H4 | [EV-14](#ev-14) |

## 6. Gaps

| ID | Gap | Evidence | What exists now | What is still missing |
|---|---|---|---|---|
| G1 | Live replication is op-level proxying with **no per-write acknowledgement**: after 4 retries the master drops the op, and the client has already been told the write succeeded | [EV-03](#ev-03), [EV-13](#ev-13) | Aggregate and per-destination drop counters; Main 4d attempts resync. Chart alerts require deployment routing. | Reliable reconstruction dispatch, persistent repair-pending state and completion evidence (SAF-02/05). |
| G2 | No content-level comparison between master and replica | [EV-12](#ev-12) | `flare_operator_replica_key_delta` compares `curr_items` on the 5-minute probe and alerts past 0.5% for 30m | Content. Equal counts do not prove equal keys or values; a compensating pair of a missing and an extra key is invisible. Real coverage needs sampled key comparison or checksum ranges |
| G3 | WAL sync runs **only** at reconstruction and cluster-replication initial transfer — it is not a live replication log, and the master's WAL retains only `walSizeLimitMb` / `walTtlSeconds` | [EV-13](#ev-13) | Nothing | Continuous WAL shipping so a replica resumes from its cursor after a blip. This is the root fix for G1 as well, and a large redesign: the sync-write contract, replica reads, cluster replication and migration all assume proxy semantics |
| G4 | A crashed pod stays in the client LB for the readiness detection window | [EV-14](#ev-14) | The window is now explicit and tunable per cluster (`cluster.probes`), and documented as the ejection window it is | A shorter default. Left alone deliberately: tightening costs an exec probe per pod per period and the right trade-off is per-cluster |
| G5 | Readiness feedback is circular — the probe asks flared for the state the operator gave it | [EV-04](#ev-04), [EV-05](#ev-05), [EV-14](#ev-14) | Independent data-level feedback exists where it matters most: `curr_items` probes drive the empty-master guards, the divergence gauge and the Prepare repair (LSN comparison) | A general answer. Readiness still cannot report "flared believes it is fine but is serving the wrong data" |
| G6 | flared metrics carry no **role** label, so no PromQL query can compare master against replica | [EV-15](#ev-15) | The operator computes the comparison itself (G2) | A role label on the pods or on the scraped series, which would also make most per-role dashboards possible. The operator already patches a per-partition Service selector on every failover, so it knows the role; labelling pods would churn on failover |
| G8 | The readiness probe's limbo clause reports Ready when the node's partition has **no Active master**, so a pod serving nothing stays in the client LB | [EV-14](#ev-14) | The clause exists to break a real deadlock: gating readiness there would stop an OrderedReady StatefulSet from ever recreating the peer that must become master | A way to satisfy the StatefulSet without advertising an unserving pod to clients — e.g. splitting the readiness gate from the endpoint membership |
| G7 | The operator cannot distinguish one dead process from a whole worker node going away | [EV-07](#ev-07) | `PodInfo.nodeName` is collected | Correlation by node. Failing over every replica on a lost node one by one is not the same decision as failing over one process, and the breaker is a blunt substitute |

## 7. Measured baseline (2026-09-07/08, pf-dev, 1 master + 1 slave, 15.85M keys)

| Check | Result |
|---|---|
| Keys on master missing from the slave (274k-key sample) | 0 |
| Keys only on the slave | 171, all expired residue (reaper deletes were master-local until rc58) |
| Value + CAS agreement on common keys (150 sampled) | 150 / 150 |

The sample cannot see a loss of tens of keys in 15.85M, so it bounds
divergence rather than disproving it — which is exactly G1/G2.

## 8. What this document got wrong

Historical correction log from the earlier audit: six claims overstated
protection. These resolutions explain changes made then; they are not current
verification evidence. The new audit additionally found lease-fence bypass,
undelivered resync transitions, unqualified Prepare activation, unknown-as-zero
delete input and lost repair-pending state (SAF-01–06). All former DONE rows
now refer to bounded controls with explicit verification status.

| # | The document said | The code actually did | Historical correction (not verification) |
|---|---|---|---|
| 1 | A node with repeated resync failures self-demotes to Down (D3) | `request_down_node` enqueues to `thread_type_controller`, started only by *flarei*. Under this operator the enqueue fails and nothing is sent anywhere — while flared logged "self-demoting to state_down", which is worse than silence during an incident | flared now reports that self-demote is unavailable in this process; `FlareResyncFailing` alerts on the condition instead |
| 2 | `FlareMasterMissing` detects a partition with no master | It compared cluster-wide counts: desired partitions minus active masters. A stale master parked at an out-of-range partition index offsets a genuinely masterless one and the alert stays silent | The operator now counts masterless partitions per index and the alert uses that gauge |
| 3 | The empty-master veto protects the refill that runs right after a failover | The probe feeding it was gated on "a partition is masterless **or** a mapped node's pod object is missing". The D2 trigger (pod present, NotReady) satisfies neither, so the veto degraded to its no-information fallback exactly when a master had just died — a hole opened by the D2 work itself | The gate now includes the unhealthy set |
| 4 | Both self-heals are safe on tmpfs | Only the stuck-Down path was gated on every partition having an Active master and the breaker being clear. The empty-master path deleted a pod with neither check | Both now share the same gates |

| 5 | The drain guard protects a partition from losing its master to an unfit successor | Its successor test was "a slave exists for this partition" — no state check — and `rebuildPartitionMap` files slaves of every state, so a slave still RECONSTRUCTING satisfied it. Promotion then made that partial copy an authoritative Master/Active (which stops it reconstructing), while the guard's "no successor" CRITICAL stayed silent because, to it, a successor existed. Failover had the same test | Both paths now require an **Active** successor; with none, the drain keeps the master and reports it, and failover leaves the choice to the data-aware refill |
| 6 | Pod deletion always goes through the graceful path | A force-delete helper (`--grace-period=0 --force`) guarded only by "state Down and pod in the ready list" still existed, reachable by uncommenting one line inside a legacy reconcile loop that nothing calls | Helper, caller and the dead loop removed |

Two more things the check corrected about the model rather than the code:

- flared holds **no persistent connection to the operator**. `_open_index`
  is called per operation (startup, activate, deactivate, shutdown), so
  there is no channel whose loss the operator could notice — which is why
  reachability had to be probed from the operator side rather than inferred.
- The read *balance* never reacts to health. A node leaves the read set only
  by being demoted or marked Down; a kept lone unhealthy master still holds
  balance 100. It is out of the client LB (readiness), but the headless
  Service publishes NotReady addresses by design, so anything resolving that
  name directly can still reach it.
