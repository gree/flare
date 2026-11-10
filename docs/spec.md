# Flare Specification

What flare on Kubernetes must do. The numbered requirements below are the
user's; the dates mark when a requirement was added or decided. The sections
after them give the rules that follow from the requirements and say where the
current code stands. Implementation status is as of 2026-11-09
(`feature/lossless-switch` d5703cf); operating procedures are in
[RUNBOOK.md](RUNBOOK.md).

**Normal operation** means the operator, the Kubernetes API and the network
between them and the nodes work. **Abnormal operation** means something
outside the operator's control failed: a node crashed, the network split, the
API cannot be reached.

## Requirements {#requirements}

1. **Every server is a proxy.** A request for another partition, or a write
   that reaches a slave, is forwarded to the right server.
2. **Data is versioned.** A write with a smaller version than the stored one
   is refused. If an abnormal event (a network failure, such as losing the
   Kubernetes API) leaves two masters in one partition, the resulting
   inconsistency is accepted.
3. **Master/slave.** Each partition has one master and its slaves.
4. **Automatic failover.** When a master goes down, a slave becomes master.
   The successor is the slave the operator can reach that holds the newest
   data (2026-10-27). "Newest" means: among the slaves that followed the last
   master, the one that applied the highest position (sequence) from that
   master. Positions in different histories cannot be compared, so a slave
   of another history is a candidate only when no following slave is left
   (confirmed by the user, 2026-10-27).
5. **No downtime in normal operation.** Users can read and write at any time.
6. **No downtime for planned changes.** Replacing or adding servers in normal
   operation causes no downtime.
7. **Data loss is accepted only in abnormal operation.** If a node fails
   suddenly, the writes it had not replicated may be lost. Asynchronous
   replication is enough.
8. **Replication delay.** Between a master and a slave that are close on the
   network, the read delay caused by replication is 0.5 ms or less.
9. **Storage.** RocksDB is the backend, on tmpfs or SSD.
10. **Backup.** RocksDB snapshots and WAL are backed up to S3 continuously,
    about 5 minutes behind, for disaster recovery.
11. **Building a slave.** A slave is built from the master's data: a RocksDB
    snapshot and WAL, or, in the legacy mode, a full dump of keys and values.
12. **An unreachable node goes down.** The operator is what moves a node
    between states, so a node it cannot reach is marked down at once and
    becomes a proxy. If it was a master, a node_map promoting a slave is sent
    as soon as possible; if it was a slave, another slave is built. Whether a
    node is unreachable is decided the way the flare index server on EC2
    decides it (a number of retries with a wait between them).
    **When the operator reaches no node at all**, the cause is taken to be
    the Kubernetes API or the network, and the operator does **nothing**:
    no down, no promotion, only an alert. Nothing is moved while the network
    is suspect (user decision, 2026-10-31).
13. **A duplicate master is resolved.** While the operator and the
    Kubernetes API work, two masters in one partition must not last: one is
    marked down and the partition recovers at once. A node that calls itself
    master but is not the master in the operator's node_map is a problem
    only for clients connected to it directly; the load balancer and the
    other nodes (which hold the correct node_map) do not send to it.
    Inconsistency is not accepted here: every node gets the same node_map,
    so a node that claims master under a node_map version other than the one
    the operator sent is detected and treated as down (user decision,
    2026-10-31).

## Rules in normal operation {#normal}

Sources: [SAFETY-TODO.md](SAFETY-TODO.md),
[design-authoritative-history.md](design-authoritative-history.md),
[STPA-node-state.md](STPA-node-state.md). SAF-NN refers to the items in
SAFETY-TODO.md.

- **node_map distribution.** Only the current leader sends a node_map, and
  only from settled state; a former leader's stale state is never sent
  (SAF-01). The leader does not send unless its lease is confirmed.
- **node_map versions only increase.** The operator reads the version each
  node applied and resends when a node is behind (SAF-09).
- **A failed forward rebuilds the slave.** When a forward from the master to
  a slave fails, the slave is taken down and rebuilt from the master (WAL
  delta or full dump) (policy of 2026-10-27).
- **Continuous WAL replication.** A slave follows the master's WAL. A change
  that arrives by forward or by WAL is applied by the same rule: only when
  its source sequence is higher; a delete is a tombstone (SAF-10b–d). WAL
  follow fills the gaps of dropped forwards, so fewer rebuilds are needed.
  - Decision of 2026-10-31: off in the first release, on from the next.
  - Status: the chart default is `cluster.rocksdb.replFollowEnabled: true`.
    pf-dev turned it on 2026-11-06 (moc2-k8s #10384).
- **Promotion.** The successor is the reachable slave with the newest data
  (requirement 4). An empty copy or one being rebuilt is never promoted.
- **Copies are kept until replaced.** A copy is not removed before a copy
  that replaces it exists (copy retention / copy protection). flared sees only
  its own copy, so on its own it never discards one: a rebuild receives the
  new copy beside the old one and switches when it is complete. That needs
  room for two copies; without it the rebuild parks
  (`rebuild_blocked=no_space`) and keeps the old copy.
- **A redundant copy is discarded on the operator's word** (user decision,
  2026-11-10). A copy that serves nothing — a proxy's, or that of a slave
  waiting for or parked in a rebuild — is useless while its partition has a
  master and at least one Active slave of the master's current history on
  another Pod. Then the operator tells that node it may discard its copy, and
  the node discards it before it rebuilds, so the rebuild needs room for one
  copy.
  - **Kept otherwise.** When only the master is left, or the partition has
    no master, a proxy's copy can be the last data: a masterless partition
    gets its new master from a node that holds data, a proxy included,
    before an empty one.
  - **Never discarded by this rule.** The master's copy, a promotion
    candidate, and quarantined or retained copies (those need a
    `FlareCopyDiscardApproval`).
  - **Bound to what was checked.** The permission names the Pod (UID), its
    copy and the node_map version it was judged under. The node refuses it
    if any of them changed, and the operator checks the condition again
    before each grant.
  - Background: on pf-dev (2026-11-05 and 2026-11-10, rc70 and rc71 rolls)
    a replica rebuilt from the master that was about to hand over kept a
    5 GB copy of the old history in an 8 GiB tmpfs. Its rebuild needed
    7.4 GB, parked on `no_space`, and stayed parked until the Pod was
    deleted by hand, while the master and another slave held all the data.
  - Status: implemented (flare-redundant-copy-discard). The operator decides
    it for a rebuild parked on `no_space` (`FLARE_OPERATOR_REDUNDANT_COPY_DISCARD=off`
    turns it off); flared writes `copy.discarded` before it wipes, so a crash
    finishes the wipe and the emptied copy is never promotable until a
    verified copy is switched in.
- **Planned master switches are ordered handovers.** Any switch the operator
  starts on a reachable master (Pod delete, rolling update, drain, cordon)
  loses no acknowledged write and returns no error; a write that arrives
  during the switch waits briefly for the new master.
  1. The old master is demoted.
  2. The operator confirms it applied the demotion and has no forward in
     flight to the successor.
  3. The successor is promoted.

  A deadline or an unfit successor aborts the switch and restores the old
  master. This replaced the earlier fence, which stopped writes for about
  46 s.
- **Disruptive operations are gated.** The node guard webhook
  (`nodeGuard.enabled: true` by default) holds Pod eviction, Pod delete and
  StatefulSet updates of a node holding data until the handover is done. The
  StatefulSet uses `updateStrategy: OnDelete`, and the operator replaces the
  Pods one at a time. See [RUNBOOK.md#upgrading](RUNBOOK.md#upgrading).
- **A cordoned node is moved off proactively.** When a node is cordoned, the
  operator moves each flare node on it before a drain evicts it. No
  replacement copy is built in advance; the copy being moved is gone until
  its replacement has synced.
  1. A master is first handed over to a slave on another node (above).
  2. The node is demoted to a proxy, and its serving label is removed so
     the client Service and load balancer stop sending to it.
  3. Once it gets no new connections, the Pod is deleted: by the drain's
     eviction, or by the operator 60 s after release.
  4. The StatefulSet recreates the Pod on another node, and it syncs from
     the master as a slave.
  5. Once synced, it gets its serving label back.

  While the Pod is being recreated and synced, the partition has one copy
  fewer (in the pf-dev test of 2026-11-09, about 3.5 minutes for 15.9
  million items). The move starts only if the partition has at least
  `nodeReplacement.minCopies` (default 3) real copies, counting the one
  being moved. With 3 copies, the master and one more copy remain during
  the move. See
  [RUNBOOK.md#cordon-move](RUNBOOK.md#cordon-move).
- **History continuation after a handover** (PR #151). The remaining
  replicas take over the new master's history instead of rebuilding. Off
  unless the operator runs with `FLARE_OPERATOR_HISTORY_CONTINUATION=on`, and
  only effective with WAL follow on.
- **Cluster migration is kept.** Moving a whole flare cluster to another
  Kubernetes cluster (FlareMigration / cluster replication; used for the move
  from AWS to pf-dev) seeds per key and stops writes until the switch. It is
  a different feature from replacing nodes (requirement 6) and stays (user
  decision, 2026-10-31).

## Rules in abnormal operation {#abnormal}

- **Unknown is not healthy.** A value that cannot be observed or read is
  Unknown; it is never taken as "healthy" or "empty". The operator confirms
  a Pod's identity (UID, boot id, copy id) before deleting or promoting it
  (SAF-04, SAF-08).
- **The 300 s last-resort grace.** It is not a delay on every promotion.
  - **When it applies.** Only after a master's data-plane failure is
    confirmed and the normal rules find no successor. If a reachable slave
    that is not empty and not being rebuilt exists, the switch to the newest
    copy happens without waiting (requirements 4 and 12).
  - **While it runs.** The partition is masterless and alerts. The grace
    starts at the first "no candidate" decision after the failure is
    confirmed. A failed operator or API read, or an unknown state, neither
    confirms a failure nor starts the grace.
  - **When it expires with still no normal candidate.** Only the newest copy
    confirmed reachable, not empty and not being rebuilt is promoted, and
    `PROMOTION NOT LOSS-FREE` is logged. Data loss is accepted here
    (requirement 7).
  - **Never promoted, even after the grace.** Copies that are empty, being
    rebuilt, quarantined, or unobservable or in an unknown state. If no
    other copy is left, the partition stays masterless with a CRITICAL alert
    and needs manual recovery.
  - **The old master coming back** does not hold a switch for 300 s when a
    normal candidate exists.
- **Circuit breaker.** When too many nodes are down at once, automatic
  promotion and deletion stop (SAF-11).
- **Lost lease.** A leader whose lease is not renewed stops: it sends no
  node_map and runs no step until the lease is confirmed again (fail
  closed).
- **Lost node_map at startup.** The operator does not rebuild the cluster as
  new without approval (SAF-09).
- **History comparison follows requirement 4.** A slave that followed the
  last master is not excluded by a strict history check alone. When no
  following copy is left, copies of another history are handled by
  requirement 4 and the last-resort rule above; a different history alone
  does not keep a partition masterless forever. Empty, rebuilding,
  quarantined and unobservable copies are still never promoted.
  - Background: this went wrong once. The master's Pod came back under the
    same name; the remaining slave kept its old history and was not rebuilt,
    so a drain found no successor (flare-bug-same-key-repromotion).
- **Restore from backup.** When the data is left only in the backup, the
  restored copy must be able to become master (user decision, 2026-10-31).
  The restore-provenance procedure of the SAF-10 branch is not carried
  over, and SAF-10 is not being reworked.
- **WAL integrity.** WAL batches are checked with CRC-32; a slave that
  receives a corrupt batch rebuilds itself.
- **Empty master.** A master whose data became empty is switched to a slave
  that has data.
- **Unreachable node** (requirement 12). An unreachable node is marked down
  and becomes a proxy. A master is taken down only when there is a
  successor, and the successor must be reachable from the operator. When the
  operator reaches no node, nothing is done. Status: implemented
  (flare-rule12-unreachable-down).
- **Duplicate master** (requirement 13). A node claiming master under
  another node_map version is detected and marked down. Status: implemented,
  with the metrics `flare_operator_duplicate_master_claims` and
  `flare_operator_duplicate_master_down`
  (flare-rule13-duplicate-master).
- **C′: only the control plane is cut.** If clients still reach the old
  master while the operator cannot, the old and the new master can both
  accept writes. Write authority (a promise with a TTL that stops the old
  master) was built on the SAF-10 branch but is not in this release line.
  This is an accepted gap under requirement 2.
