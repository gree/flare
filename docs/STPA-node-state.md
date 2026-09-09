# STPA: node state transitions (when does a node go Down?)

Hazard analysis of the operator↔flared control loop, focused on the question
that keeps coming up in incidents: **when does a node leave the serving set,
who decides, and on what evidence?** Written after the 2026-09-07 finding
that a segfaulted flared was never detected at all.

Method: STAMP/STPA — losses, hazards, control structure, then Unsafe Control
Actions (UCA) and the scenarios that produce them.

Every row carries a status, and every status was checked against the code
rather than against memory. That check found four things this document had
claimed and the code did not do; they are listed in section 8, and the ones
worth fixing were fixed.

| Mark | Meaning |
|---|---|
| **DONE** | Implemented, wired, and reachable on the live path |
| **PARTIAL** | Implemented with a stated limitation |
| **GAP** | Not implemented; the hazard is currently uncovered |

## 1. Losses

| ID | Loss |
|---|---|
| L1 | Durable data loss (keys gone from every copy) |
| L2 | Incorrect read (client gets a stale value, or a miss for a key that exists) |
| L3 | Write unavailability (a partition takes no writes) |
| L4 | Read unavailability |
| L5 | Operator/on-call cannot tell whether the cluster is healthy |

## 2. Hazards

| ID | Hazard | Leads to | Detection | Mitigation |
|---|---|---|---|---|
| H1 | A partition has no Active master | L3 | **DONE** — `flare_operator_partitions_masterless`, counted per partition index, alert `FlareMasterMissing`. (Was cluster-wide arithmetic that a stale out-of-range master could offset; corrected.) | **DONE** — failover with promotion, then the masterless refill; both run on the normal path and on the breaker-tripped recovery path. **Except** `autoResetEnabled=false`, which parks in a fully inert state with no refill at all |
| H2 | An Active master holds less data than a replica of the same partition | L2, then L1 when replicas reseed from it | **PARTIAL** — the self-heal fires only at *exactly zero* keys; a stale-but-non-empty master is caught only as a warning by `flare_operator_replica_key_delta` | **PARTIAL** — mint prevention (data-bearing veto in the refill, bootstrap-only P0 fast path) plus the empty-master self-heal. The veto covers the `lastMasterOf` candidate; the Active-slave candidate has no data check |
| H3 | A replica diverges from its master with no detection | L5 now, L1/L2 when it is promoted | **PARTIAL** — `flare_node_proxy_write_dropped` (writes the master gave up on) and `flare_operator_replica_key_delta` (count comparison). Neither compares *content* | **GAP** — nothing repairs a diverged replica automatically; only a reconstruction does, and nothing triggers one. See G1/G2 |
| H4 | A node is in the serving set (client LB or read balance) while not serving correctly | L2, L4 | **DONE** — readiness gate (client LB), `flare_operator_nodes_unhealthy`, and `flare_operator_nodes_unreachable` for the operator→pod path | **PARTIAL** — K8s ejects a NotReady pod from the client LB, and D2 takes an unhealthy node out of the topology. But read *balance* itself never reacts to health: only a demote or Down removes a node from it |
| H5 | The last data-bearing copy of a partition is destroyed | L1 | **DONE** — `flare_operator_drain_no_successor` (CRITICAL) for the drain case | **DONE** — the drain guard refuses to demote a master with no successor; both pod-deleting self-heals are gated on every partition having an Active master and the breaker being clear |
| H6 | Two nodes act as master for the same partition | L1, L2 | — | **DONE** — machine-checked bound (`CLE` / at-most-one-master) over the state transforms, plus `demoteDuplicateMasters` as the repair step for the merge race |

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

| # | Trigger | Detector | Condition | Action | How it leaves Down | Status |
|---|---|---|---|---|---|---|
| D1 | Pod object gone (delete, evict, reschedule) | operator `detectDeadNodesPure` | key absent from F1, role≠Proxy, state∉{Down,Prepare} | demote to Proxy/Down/partition −1, promote a data-bearing slave | new pod registers (F3) → Prepare → catch up | **DONE** |
| D2 | Pod present but not serving (segfault, hang, wedge) | operator, **rc59** | F2 NotReady for `FLARE_UNREADY_DEAD_CYCLES` ticks (default 6 ≈ 30s) on top of kubelet's 3 failures | same as D1 — **except** a master with no promotable successor, which is KEPT as master (`unhealthyMastersKept`) and only logged CRITICAL | container restart (kubelet liveness, or D6) → re-register | **DONE** |
| D3 | Repeated resync failure | flared itself | failure streak ≥ `rocksdb-resync-failure-threshold` | flared asks the index to mark it down (`request_down_node`) | human, or restart | **GAP → alert only.** `request_down_node` enqueues to a controller thread that only *flarei* starts, so under this operator the call fails and nothing happens. flared's log said it had self-demoted; corrected to say it could not. `FlareResyncFailing` is now the signal |
| D4 | Graceful drain, no successor | operator drain guard | Terminating master, no promotable slave | **NOT demoted** — stays master to the end; CRITICAL alert | pod dies; partition is masterless until a copy returns | **DONE** |
| D5 | Mass failure | operator circuit breaker | ≥ `tripThresholdPercent` of Active nodes dead at once | failover **paused**: no Down transitions | breaker clears when the fraction drops | **DONE** |
| D6 | Stuck Down | operator, **rc59** | state Down + role Proxy + pod present for `FLARE_DOWN_RESTART_CYCLES` ticks (default 60 ≈ 5 min), every partition has an Active master, breaker not tripped | graceful pod delete (one per tick) | re-registration after restart | **DONE** |

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
route instead of the clean rejoin. Keeping it master costs nothing, because
a NotReady pod is already out of the client LB. This is the same decision
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
masterless, so `promoteMasterlessPartitions` seats a data-bearing copy on
the next tick (rc55 guards prefer one that actually holds data). This path
is ~5–10s, faster than D2, and it is why the 2026-09-07 segfault recovered
even though nothing detected it.

## 4b. Failure patterns → which detector fires

| Pattern | What K8s does | Signal the operator sees | Path | Latency | Status |
|---|---|---|---|---|---|
| Process exits (segfault, panic) and restarts promptly | container restarts, pod keeps its name and IP | `node add` re-registration (F3) | **R1** — no Down at all | ~5–10s | **DONE** |
| Same, but CrashLoopBackOff keeps it down | backoff grows, pod stays NotReady | Ready=False (F2) | **D2** | kubelet ~15s + operator ~30s ≈ 45s | **DONE** |
| OOMKill, single | container restarts (exit 137) | as above | **R1** | ~5–10s | **DONE** |
| OOMKill, repeating | CrashLoopBackOff | Ready=False | **D2** | ~45s | **DONE** |
| flared hangs but the port still accepts | tcpSocket liveness **passes** | readiness exec times out → Ready=False | **D2** | ~45s (liveness cannot see this) | **DONE** |
| Pod deleted / evicted / rescheduled | pod object disappears | key absent from the pod list (F1) | **D1** | 1 tick | **DONE** |
| Graceful delete with preStop | Terminating, still Ready | deletionTimestamp | **D4** drain (demote + promote inside the window) | 1 tick | **DONE** |
| Worker node unreachable (kubelet dead, VM hung) | node Ready→Unknown after the monitor grace period, then the node controller marks its pods NotReady; eviction adds a deletionTimestamp later (default 5 min) | Ready=False, then Terminating | **D2**, later **D4** | ≈ node grace + 30s (before rc59: only the 5-min eviction) | **DONE** |
| Node object deleted / VM gone | pods garbage-collected | key absent from the pod list | **D1** | 1 tick | **DONE** |
| Network partition: pod alive and Ready, operator cannot reach it | nothing — kubelet is local and keeps reporting Ready | none (broadcasts fail, bounded and logged) | **NOT DETECTED** | — | **DONE (alert only)** — `flare_operator_nodes_unreachable`: the operator probes each Ready pod's flared port every ~30s. Never fed into failover, on purpose |
| flared alive and Ready but serving diverged data | nothing | none | **NOT DETECTED** (G2) | — | **PARTIAL** — count-level only (G2) |

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

### A1a — mark a node Down / fail over

| Type | UCA | Hazard | Status |
|---|---|---|---|
| Not provided | Node is not serving but stays Active (segfault with the pod present) | H1 (crashed master, no failover), H3, H4 | **was the 2026-09-07 bug**; fixed by D2 |
| Not provided | Replica silently misses writes but answers probes | H3 | **GAP G1/G2** — no per-write ack, no anti-entropy |
| Provided | Healthy replica demoted on a false positive | H5 if both replicas are hit | mitigated: kubelet 3 failures + 6 operator ticks; breaker (D5) caps mass demotion |
| Wrong order | Master demoted before a data-bearing successor exists | H1, H2 | mitigated: drain guard (D4), promotion prefers an Active data-bearing slave (rc55) |
| Provided | Lone master (no replica) demoted on D2 — strips the partition and breaks the clean rejoin for a process about to return | H1 | mitigated rc59: `unhealthyMastersKept` keeps it, CRITICAL log only |
| Too long | Node left Down forever with a healthy process | L4 (capacity), H5 if the peer then fails | mitigated: D6 |

### A1b — promote a node to master

| Type | UCA | Hazard | Status |
|---|---|---|---|
| Provided | Empty or stale node crowned master | H2 | mitigated rc55: refill vetoes a non-data-bearing `lastMasterOf` holder; P0 fast path is bootstrap-only; rc56 demotes a sitting empty master via the drain path |
| Provided | Two masters for one partition | H6 | proven bound: `CLE` / `atMostOneMaster` over the commit path; `demoteDuplicateMasters` downstream |
| Not provided | Masterless partition never refilled | H1 | mitigated: masterless refill each tick; `FlareMasterMissing` alert |
| Wrong timing | Promote a Prepare node that never synced | H2 | mitigated: vacuous-activation guard (refuse Prepare→Active with no Active master) |

### A2 — delete a pod

| Type | UCA | Hazard | Status |
|---|---|---|---|
| Provided | Deleting the last data-bearing copy (tmpfs ⇒ erase) | H5, L1 | mitigated: D6 requires every partition to have an Active master, breaker not tripped, one pod per tick |
| Provided | Deleting a pod mid-reconstruction, looping | L4 | mitigated: Prepare nodes are excluded from dead detection; the Prepare watchdog only warns |

### A1c — broadcast topology

| Type | UCA | Hazard | Status |
|---|---|---|---|
| Not provided | flared keeps an old map (master unaware it is master) | H1, H2, H4 | mitigated rc54/rc55: merge carve-out, all broadcast waits bounded (an unbounded one froze the loop 22 min) |
| Too late | Map change not pushed because the version did not advance | H4 | mitigated rc54 (version bump on registration) — the underlying "broadcast only on version change" design remains |

## 6. Gaps

| ID | Gap | Status | What exists now | What is still missing |
|---|---|---|---|---|
| G1 | Live replication is op-level proxying with **no per-write acknowledgement**: after 4 retries the master drops the op, and the client has already been told the write succeeded | **PARTIAL** | `flare_node_proxy_write_dropped` counts the drops, names destination and key in the log, and pages via `FlareProxyWriteDropped` | Repair. Nothing reconstructs the replica that missed the writes. The counter is also unlabeled, so it cannot say *which* replica diverged (the log line can) |
| G2 | No content-level comparison between master and replica | **PARTIAL** | `flare_operator_replica_key_delta` compares `curr_items` on the 5-minute probe and alerts past 0.5% for 30m | Content. Equal counts do not prove equal keys or values; a compensating pair of a missing and an extra key is invisible. Real coverage needs sampled key comparison or checksum ranges |
| G3 | WAL sync runs **only** at reconstruction and cluster-replication initial transfer — it is not a live replication log, and the master's WAL retains only `walSizeLimitMb` / `walTtlSeconds` | **GAP** | Nothing | Continuous WAL shipping so a replica resumes from its cursor after a blip. This is the root fix for G1 as well, and a large redesign: the sync-write contract, replica reads, cluster replication and migration all assume proxy semantics |
| G4 | A crashed pod stays in the client LB for the readiness detection window | **PARTIAL** | The window is now explicit and tunable per cluster (`cluster.probes`), and documented as the ejection window it is | A shorter default. Left alone deliberately: tightening costs an exec probe per pod per period and the right trade-off is per-cluster |
| G5 | Readiness feedback is circular — the probe asks flared for the state the operator gave it | **PARTIAL** | Independent data-level feedback exists where it matters most: `curr_items` probes drive the empty-master guards, the divergence gauge and the Prepare repair (LSN comparison) | A general answer. Readiness still cannot report "flared believes it is fine but is serving the wrong data" |
| G6 | flared metrics carry no **role** label, so no PromQL query can compare master against replica | **GAP** | The operator computes the comparison itself (G2) | A role label on the pods or on the scraped series, which would also make most per-role dashboards possible. The operator already patches a per-partition Service selector on every failover, so it knows the role; labelling pods would churn on failover |
| G7 | The operator cannot distinguish one dead process from a whole worker node going away | **GAP** | `PodInfo.nodeName` is collected | Correlation by node. Failing over every replica on a lost node one by one is not the same decision as failing over one process, and the breaker is a blunt substitute |

## 7. Measured baseline (2026-09-07/08, pf-dev, 1 master + 1 slave, 15.85M keys)

| Check | Result |
|---|---|
| Keys on master missing from the slave (274k-key sample) | 0 |
| Keys only on the slave | 171, all expired residue (reaper deletes were master-local until rc58) |
| Value + CAS agreement on common keys (150 sampled) | 150 / 150 |

The sample cannot see a loss of tens of keys in 15.85M, so it bounds
divergence rather than disproving it — which is exactly G1/G2.

## 8. What this document got wrong

Every claim above was re-checked against the code. Four were wrong, in the
direction that matters — the document credited the system with protection it
did not have.

| # | The document said | The code actually did | Resolution |
|---|---|---|---|
| 1 | A node with repeated resync failures self-demotes to Down (D3) | `request_down_node` enqueues to `thread_type_controller`, started only by *flarei*. Under this operator the enqueue fails and nothing is sent anywhere — while flared logged "self-demoting to state_down", which is worse than silence during an incident | flared now reports that self-demote is unavailable in this process; `FlareResyncFailing` alerts on the condition instead |
| 2 | `FlareMasterMissing` detects a partition with no master | It compared cluster-wide counts: desired partitions minus active masters. A stale master parked at an out-of-range partition index offsets a genuinely masterless one and the alert stays silent | The operator now counts masterless partitions per index and the alert uses that gauge |
| 3 | The empty-master veto protects the refill that runs right after a failover | The probe feeding it was gated on "a partition is masterless **or** a mapped node's pod object is missing". The D2 trigger (pod present, NotReady) satisfies neither, so the veto degraded to its no-information fallback exactly when a master had just died — a hole opened by the D2 work itself | The gate now includes the unhealthy set |
| 4 | Both self-heals are safe on tmpfs | Only the stuck-Down path was gated on every partition having an Active master and the breaker being clear. The empty-master path deleted a pod with neither check | Both now share the same gates |

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
