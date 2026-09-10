# Design review guide

Written for someone about to review this system. It says what it is, where
it currently stands, what to read in what order, and — most usefully — where
I would push if I were reviewing rather than writing.

Last checked against the code: 2026-09-10.

## 1. What the system is, in one page

flared is unchanged upstream flare: a memcached-compatible store, here on a
RocksDB backend. What replaces upstream's `flarei` index server is an
**operator** that owns cluster topology.

```
   FlareCluster CRD                          human / ArgoCD
          |                                        |
          v                                        v
  +---------------------------------------------------------+
  |  flare-operator   (leader-elected, 5s reconcile tick)    |
  |    decides: who is master, who reconstructs, who is out  |
  |    acts by: node-sync broadcast, pod delete, config +    |
  |             SIGHUP, Service selector patch               |
  +---------------------------------------------------------+
       ^ what it can see                    | what it does
       | pod list, pod Ready, registrations,  v
       | node-state reports, stats probes  +--------------+
       |                                   |   flared     |
       +-----------------------------------|   (data)     |
                                           +--------------+
                                            ^          |
                                        kubelet      clients
                                    (probes,          (via LB)
                                     restarts)
```

Two properties are worth holding onto before reading anything else:

**The data plane keeps serving if the operator dies.** flared runs on its
last topology. Control-plane incidents are urgent but are not instant
outages.

**Live replication is op-level proxying, not WAL.** The master forwards each
write to its replicas as an op. WAL shipping exists but runs only during
reconstruction and cluster-replication bootstrap. This single fact explains
most of the sharp edges below, and the code carried comments asserting the
opposite for a long time.

## 2. Where it stands today

- Operator and flared at **rc63**. The pf-dev cluster runs **rc56**; the
  bump to rc63 is open as a deployment PR and would be one rolling restart.
- pf-dev is currently **empty and parked** (backups suspended, bootstrap
  off) after finishing an inter-cluster replication experiment.
- The Lean library carries **151 theorems**; elaborating it checks them.
  They bound safety (at most one master per partition through the commit
  path), not liveness.
- E2E is **26 suites across 4 parallel CI shards**, ~45 minutes wall clock.
- Alerting exists in the chart but is **disabled on the pf-dev overlay**
  (`monitoring.prometheusRule.enabled: false`), so no alert currently
  reaches anyone there. That is an open decision, not an oversight.

## 3. What has actually gone wrong, and what we did about it

This section exists because the shape of the failures explains the shape of
the engineering — including why a formally verified operator still needed a
hazard analysis.

**The proofs cover one class, and that class has stayed clean.** Split brain
— two masters for one partition — is bounded by machine-checked properties
over the commit path, plus a duplicate-master repair step. It has not bitten
us in production. That is the good news and also the whole point of the next
paragraph.

**Nearly every real incident came from two other classes.** Whether a node
is *alive*, and whether a copy of the data is *good*. Proofs could not see
either, because they reason about state transitions **given the inputs**;
they say nothing about whether the inputs describe reality. When the
operator believed a segfaulted pod was healthy, no theorem was violated —
the premise was simply false. That is exactly the question STAMP/STPA asks:
what feedback does the controller actually have, and what happens when it is
missing, late, or wrong. Hence
[STPA-node-state.md](STPA-node-state.md).

| Pattern | What happened | Countermeasure | Kind of mechanism |
|---|---|---|---|
| **Split brain** | (none in production) | At-most-one-master bound over the commit path; duplicate-master repair | Proof |
| **Liveness misjudged** | A segfaulted flared was never detected: pod existence was the only liveness signal, so the node stayed Active, the master proxied writes into a dead socket, and a crashed **master** would get no failover at all | Pod-Ready streak feeds the existing failover path; a lone master with no in-sync successor is kept rather than stripped | Detection |
| | Nodes wedged as Proxy — once for 14 h — because a registration-epoch tiebreak discarded the assignment every tick, and once because a stale map and a tied epoch left the cluster all-proxy | Epoch monotonicity on registration; a carve-out so an unassigned Proxy may be seated as Slave | FSM guard |
| | A slave sat in Prepare for 7 h 27 m because its one-shot "reconstruction complete" event was lost, blocking rolling updates | Re-derive the fact from the replication cursor instead of waiting for the event again | Level-triggered repair |
| | The reconcile loop hung 22 minutes inside a topology broadcast: one pod accepted the connection and stalled | Every wait in the broadcast bounded | IO deadline |
| | `Down` never clears itself, so anything that entered it stayed stuck | Restart the pod after a gated interval | Recovery path |
| **Data health misjudged** | An empty master was crowned over a replica holding 15.8 M keys, and kept serving nothing | Promotion prefers a data-bearing copy; the fast path for the first node is bootstrap-only; a sitting empty master is handed off through the drain path | Guard + probe |
| | Promotion accepted a slave that was still **reconstructing** — which stops its reconstruction and starts it serving a partial copy — while the drain guard's "no successor" alarm stayed silent because, to it, a successor existed | Only an Active successor counts | Guard |
| | The expire reaper deleted on the master only. Its comment claimed the WAL carried the deletes to replicas; live replication is op-level proxying, so it did not. A replica accumulated ~10 k stale keys over 12 days | Reaped keys are forwarded as version-carrying deletes | Replication fix |
| | Writes the master could not forward were dropped after four retries, silently, with the client already told the write succeeded | Counted per destination; the affected replica is sent back through reconstruction | Accounting + repair |
| | A cross-cluster seed failed twice over: the physical push was declined by an unconverged node, and the fallback dump had every one of 15.8 M writes acknowledged and stored nowhere while reporting success | Route to the master before checking layout; check every write's result | Protocol fix |
| **Resource exhaustion** | tmpfs clusters OOMed because backup checkpoints hardlink-pin compacted-away files, and a full data dir crashed flared through null-database dereferences | Retain one checkpoint on tmpfs; null guards and an emergency reopen; memory measured at the pod cgroup, where the OOM killer looks | Config + hardening |
| **Untrusted input** | One `dump` request with an out-of-range partition size crashed a serving node — the value indexed a table unchecked | Bounds check, and reject inconsistent parameters at parse time | Input validation |
| **Documentation drift** | Six claims in the hazard analysis described protection the code did not have, including a self-demote that could never fire while logging that it had | Every row re-checked against the code and marked; the corrections recorded in the document itself | Verification pass |

Two things a reviewer should take from the table. The countermeasures are
mostly *detection and guards*, not proofs — because the failures were about
the relationship between the controller and reality, which is not where
proofs help. And the same root cause appears repeatedly in different
disguises: **an internal write path that no one told the replicas about**
(the reaper, the dropped proxy writes, the dump that stored nothing). If you
add a path that mutates data, the first question is how a replica learns.

## 4. Reading order

About two hours, in this order:

1. **[STPA-node-state.md](STPA-node-state.md)** (20 min) — the hazard
   analysis. Losses, hazards, the control structure, the full table of what
   makes a node leave the serving set, and the gaps. Every row carries a
   status that was checked against the code. Start here even if you plan to
   read code: it is the map.
2. **`StateMachine/K8sReconciler.lean`** (40 min) — the reconciler. The
   interesting functions are `detectDeadNodesPure`,
   `handleFailoverWithPromotionSingleKey`, `handleDrainWithPromotionSingleKey`,
   `findActiveSuccessor`, `promoteMasterlessPartition`, `mergeNodeEntry` and
   `unhealthyMastersKept`. Read the doc comments — they carry the incident
   each guard came from.
3. **`Main.lean`, sections 4c–4f** (20 min) — the self-healing that lives in
   the IO shell rather than the state machine: Prepare repair, empty-master
   self-heal, liveness and stuck-Down recovery, reachability, replica
   resync. Ask whether each belongs there.
4. **[RUNBOOK.md](RUNBOOK.md)**, the alert sections (20 min) — every alert
   has one. It is the fastest way to see which failure modes are understood.
5. **`src/lib/queue_proxy_write.cc` and `handler_reaper.cc`** (20 min) — the
   two places where flared writes to a peer, and the two places where that
   has silently failed.

## 5. Where I would push

These are the questions I would ask, including the ones I do not have good
answers to.

**Is the pure/impure split in the right place?** The state machine is pure
and proven; the self-heals in `Main.lean` are neither. They were put there
because they need probes (curr_items, LSNs) that the pure layer cannot
perform — but "needs IO to *decide*" and "needs IO to *observe*" are
different, and the decision half could be pulled into the proven layer.

**The pod-side input is not typed.** Events from flared are a proper sum
type and matched exhaustively. Facts about pods arrive as five parallel
lists of strings — `pods`, `zones`, `terminating`, `dataBearing`,
`unhealthy` — so a pod's condition is set membership. Lean checks nothing
there. This is not hypothetical: a bug shipped in rc59 because "absent from
the dataBearing list" means both *has no data* and *was not probed*. A
`PodCondition` sum type plus `Option Bool` would have made it
unrepresentable. Proposed, not done.

**Several pod signals are not collected at all.** `restartCount`, the
terminated reason and exit code (OOMKilled vs SIGSEGV vs evicted), and the
waiting reason. `nodeName` is collected and unused, so the operator cannot
tell one dead process from a whole worker node going away.

**Feedback the operator cannot get.** Readiness is circular — the probe asks
flared for the state the operator gave it — so it can report "my instruction
did not land" but never "this node is serving the wrong data". Reachability
had to be probed actively because flared holds no persistent connection to
the operator.

**Replication has no per-write acknowledgement.** Four retries, then the
write is dropped and the client has already been told it succeeded. This is
counted per destination and now triggers a resync of that replica, but the
catch-up falls back to a full dump whenever the replica's cursor is not
usable — which, under proxy replication, is most of the time. Carrying the
master's LSN on proxied writes would make it incremental. The full fix is
continuous WAL shipping, deliberately not attempted: sync-write semantics,
replica reads, cluster replication and migration all assume proxy.

**Divergence is only visible by key count.** Equal counts do not prove equal
content. A compensating pair of a missing and an extra key is invisible.
There is no anti-entropy.

## 6. How much to trust the documentation

Not blindly, and the reason is instructive. In September 2026 every claim in
the hazard analysis was re-checked against the code. **Six were wrong, all in
the same direction — the document credited the system with protection it did
not have.** Among them: a self-demote path that could never fire while
logging that it had; promotion accepting a slave that was still
reconstructing; a masterless-partition alert that cluster-wide arithmetic
could silence.

They are listed in [STPA-node-state.md](STPA-node-state.md#8-what-this-document-got-wrong).
The lesson for a reviewer: when a comment says a guard exists, check that
the guard is reachable on the live path. Several were not.

The older review documents listed in the [README](../README.md#where-to-read-what)
were accurate when written and have not been maintained. Treat them as
statements of intent.

## 7. Open decisions

| Decision | Why it is open |
|---|---|
| Enable alerting on pf-dev | The chart's alerts do not deploy there. Turning them on changes who gets paged |
| Type the pod-side input | Would have prevented a shipped bug; costs a refactor across the FSM, the IO shell and the proof scripts |
| Carry the master LSN on proxied writes | Turns post-blip catch-up from a full dump into an incremental resync |
| Continuous WAL shipping | The root fix for replication gaps, and a redesign of everything that assumes proxy semantics |
