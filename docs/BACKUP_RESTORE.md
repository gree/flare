# Flare Backup & Restore (RocksDB backend)

Replication and PVCs protect against **hardware failure**. They do NOT
protect against **logical destruction**: a bad `flush_all`, an application
bug deleting keys, or an operator mistake is replicated faithfully to every
replica. The only defense is a point-in-time backup. This document describes
the two-tier backup design and the restore procedures, including their
limits.

## Architecture

```
Tier 1 (in-cluster, fast, per-pod):
  flared `backup <name>` op
    └─ rocksdb::Checkpoint → <data-dir>/backups/<name>/   (hard links, ~instant,
       application-consistent, survives flush_all — checkpoints reference
       immutable SST files that live deletes do not touch)
       retention: flared prunes to `rocksdb-backup-keep` newest (default 7)

Tier 2 (off-cluster, optional):
  CronJob: kubectl exec tar → aws s3 cp / rclone
    └─ survives PVC loss, namespace deletion, cluster loss
```

Components:

- `backup <name>` — flared text-protocol op (RocksDB backend only). Name is
  restricted to `[A-Za-z0-9._-]`, no leading dot (path-traversal guard).
  Stats: `rocksdb_backup_success` / `rocksdb_backup_failure` /
  `rocksdb_last_backup_epoch` — **alert when
  `time() - rocksdb_last_backup_epoch` exceeds ~2 backup intervals**.
- `rocksdb-backup-keep` (flared.conf, default 7, hot-reloadable via SIGHUP).
- `cluster.backup` (helm values) — ONE CronJob running ONE strictly-ordered
  script (`flare-backup-run`, baked into the `flare-backup` image): per
  partition, checkpoint -> pull -> restore-consistent 3-phase upload to
  `<url>/<cluster>/latest/p<N>/` -> verify; then, on the first successful run
  of each UTC day, a server-side copy of `latest/` to a dated, pruned
  `snapshots/<date>/` generation. In-process ordering means the daily
  generation can never race a running delta; `concurrencyPolicy: Forbid` +
  `activeDeadlineSeconds` below the cadence handle self-overlap and hangs.
  Location/auth come from `cluster.objectStorage` (S3-compatible stores via
  `endpoint`; keyless web-identity via `projectedTokenAudience` + `extraEnv`,
  or a static `credentialsSecret`) — the SAME block `backupBootstrap` reads,
  so produce and restore sides cannot drift apart. Immutable uniquely-named
  SSTs mean only new ones cross the WAN on each delta. Local in-pod
  generations are a byproduct of every run (pruned by `rocksdb-backup-keep`).
- **One node per partition, not every replica.** Replicas hold identical data,
  so the jobs discover targets from the operator node map (`node sync` on
  `:12120`) and back up exactly one Active node per partition of a selectable
  `BACKUP_ROLE` (`master`, default — the freshest copy; or `slave` to offload
  the master). The S3 layout is **generation-first**, keyed by partition (NOT
  pod): `<cluster>/latest/p<N>/` is the live mirror, `<cluster>/snapshots/<date>/p<N>/`
  the dated generations — so a master change (failover) keeps a stable path.
- Restore hook in the StatefulSet startup command (PVC deployments),
  `flare-restore-hook` (shipped in the flared images; the E2E harness runs the
  same script): if `<data-dir>/RESTORE` exists, its content names a checkpoint
  directory; after the **restore provenance check** below the live DB is
  replaced by it (with a `RESTORED` marker) and the marker consumed before
  flared starts.

## Restore provenance (partition binding)

Every RocksDB copy records which partition, under which routing rule, its
data belongs to — the reserved key `__flare_partition_binding`
(`v1 partition=<p> partitions=<n> size=<s> hash=<a> resolver=<t> hint=<h>
virtual=<v>`, `stats`: `rocksdb_partition_binding`). flared (re)records it
whenever the node map makes a LIVE copy a master or an Active slave — a live
copy's partition is the operator's decision, so it is never refused for its
binding; a completed full dump, a staged copy switch and a snapshot swap drop
the old one (the new content is bound when it becomes Active). The binding
travels inside every checkpoint and backup. `partitions=<n>` is informational
and never compared: flared's count of the map's Active partitions is not a
stable fact (Prepare partitions are not in it).

Checked at three points, before anything serves the restored data:

1. **Before the live copy is replaced** (`flare-restore-hook`): the backup must
   carry a binding (`flared --checkpoint-binding <dir>`, read-only); when the
   live copy is bound and readable, both must name the same partition and
   routing rule (an unreadable — corrupt — live copy is replaced). Refused ->
   the live copy is kept and served, the marker becomes `RESTORE.refused`
   (+ `.reason`); with no live copy the pod does not start. The chart runs the
   hook only when a `RESTORE` marker exists.
   (The hook still REPLACES the live copy without keeping it once the check
   passes — keeping it is the separate in-place design, not implemented.)
2. **When the map makes the restored copy a master** (flared): a `RESTORED`
   copy (`rocksdb_restored_unverified 1`) serves as a master only of the
   partition and routing rule its binding names; an unbound restored copy (a
   backup from before bindings) is refused. Refused -> `promotion_refused 1`,
   no reads or writes as master. Verified -> the flag is cleared, durably. A
   restored copy is also no longer "restored" once a completed rebuild, a
   staged switch or a snapshot swap replaced its content (an ABANDONED rebuild
   attempt does not clear it).
3. **When the operator promotes an existing copy, or seats the first master of
   a new partition from the FSM** (the classifier, `restore provenance: …`):
   the same rule, as an abort. (The first master of a brand-new cluster is
   seated by `node add` without a read; there point 2 is the guard.)

Old backups (taken before bindings) are refused by points 1 and 2 on this
release. **Rollout hazard:** `backupBootstrap` seeds from `latest/p0/` with a
`RESTORED` marker; until a backup has been taken by the new release, a full
restart that bootstraps from an OLD backup leaves the partition without a
usable master (flared refuses the unbound restored copy). Take a backup with
the new release before relying on bootstrap (compatibility policy for old
backups: pending a decision). See RUNBOOK.md#restore-refused.

Not implemented (known gaps): a master that refuses this way is still in the
map and is NOT counted by `flare_operator_partitions_masterless` /
`FlareMasterMissing`; the partition COUNT of a backup is not compared with the
cluster's (pending a decision); the hook replaces a live copy without keeping
it once the check passes (in-place restore with retention, plan I).

## Taking a backup

Automatic: set `cluster.objectStorage.url` and `cluster.backup.enabled: true`
(adjust `backup.role`, `backup.schedule`, `backup.keepDays`).

> **Seeding a cluster over cluster replication? Keep backups OFF until the
> catch-up plateaus** — a partial backup protects nothing and each hourly
> checkpoint pins ~a full DB copy of compaction churn (RAM on tmpfs). Full
> ordering: RUNBOOK.md#replication-seeding.

> **Backup ServiceAccount name & OIDC trust.** The chart names the backup SA
> (and CronJob) `<cluster.name>-backup` so several clusters can share one
> namespace without colliding. For keyless (web-identity) auth the cloud-side
> IAM trust policy must therefore match the SA subject with a **StringLike**
> condition, e.g. `system:serviceaccount:<ns>:*-backup`, rather than an exact
> `StringEquals` on a fixed name — otherwise the renamed SA cannot assume the
> role. Pin `backup.serviceAccount.name` if you prefer an exact-match policy.

Manual (one pod):

```
printf 'backup manual-20260713\r\n' | nc <pod-ip> 12121
```

Backups are **per partition**: the CronJob checkpoints ONE node per partition
(the `BACKUP_ROLE` copy — replicas are identical, so backing up all is
redundant). For a full-cluster restore point, all partitions are backed up at
(approximately) the same time — the CronJob does this. Cross-partition
consistency is *not* atomic: partitions are checkpointed seconds apart. For a
KVS this is normally acceptable; if you need a hard cut, quiesce writes first.

## Restore

> **NOT SUPPORTED ON THE CURRENT SAF-10 CANDIDATE (branch
> `safety/saf-10-wal-replication`, from the reason-based promotion change
> ce8d661 / f9289aa on).** Do not run Case A or B on a cluster whose operator
> is built from this branch. The restored copies come back with the history
> of the backup; the operator holds the partition's LAST master history (for
> example the one a `flush_all` created) and, by design, does not promote a
> copy of a different history. The partition then stays **without a master**
> (CI: eb7bc43, run 37770467697, failover-data job 113288583371 —
> `backup-restore` test 24 failed, "PROMOTION ABORTED … unknown (its history
> … is not the last master's …)" repeated, no master after 180 s). There is no
> step in this procedure that adopts the restored history explicitly; until
> one is designed and approved (release checklist R8), these steps are valid
> only for an operator release that predates that change. Do NOT work around
> it by restarting the operator (that only erases the operator's record of
> the last history).

### Case A — single-partition cluster (partitions=1): ~~fully supported, e2e-tested~~ NOT supported on the SAF-10 candidate (see above)

1. Pick the restore point: `kubectl exec <pod> -- ls /data/flare/backups`
2. On EVERY pod of the cluster, write the marker:
   ```
   kubectl exec <pod> -- sh -c 'echo /data/flare/backups/<name> > /data/flare/RESTORE'
   ```
3. Delete all pods of the partition simultaneously:
   ```
   kubectl delete pod <pod-0> <pod-1> --force --grace-period=0
   ```
4. The StatefulSet recreates the pods; the startup hook swaps the checkpoint
   in; on releases that predate the SAF-10 reason-based promotion the
   operator re-elects a master. **On the SAF-10 candidate it does NOT: the
   partition stays without a master (see the notice above).** Verify with key
   sampling before re-enabling traffic.
   - The hook adds a `RESTORED` marker (both restore paths now do): the
     restored copy gets a new copy identity and is checked against its
     partition binding before it serves as a master.

This flow is exercised end-to-end by the `backup-restore` e2e suite
(write → checkpoint → flush_all on all replicas → marker → pod deletion →
per-key exact-value verification). That suite FAILS on the SAF-10 candidate
(eb7bc43, run 37770467697): it is not evidence that the flow works there.

### Case B — restore from object storage (PVC also lost)

The tier-2 jobs store each partition's checkpoint as an UNPACKED directory (via
`aws s3 sync`), not a tarball, keyed by partition (`p<N>`). Pick the source for
the partition you are restoring:
- most-recent mirror: `s3://bucket/<cluster>/latest/p<N>/`
- retained point-in-time: `s3://bucket/<cluster>/snapshots/<DATE>/p<N>/`
(`EP="--endpoint-url <COS/GCS/MinIO endpoint>"`, empty for AWS.)

1. Provision the new PVC/pod (StatefulSet recreates it empty).
2. Pull the checkpoint down, then copy it into EVERY pod of that partition
   under a backup name (all replicas of a partition restore from the same
   single backup):
   ```
   aws s3 sync $EP s3://bucket/<cluster>/latest/p<N>/ /tmp/<name>
   kubectl cp /tmp/<name> <namespace>/<pod>:/data/flare/backups/<name>
   ```
   (For a dated restore, sync from `…/<cluster>/snapshots/<DATE>/p<N>/`.)
3. Continue with Case A steps 2–4 (write the `RESTORE` marker naming
   `/data/flare/backups/<name>`, delete the pods, let the startup hook swap it in).
   **The same limitation applies: not supported on the SAF-10 candidate (see
   the notice at the top of "Restore").**

### Case C — multi-partition cluster: MANUAL, read this first

> Not supported on the SAF-10 candidate either: step 1 is the Case A restore
> (see the notice at the top of "Restore").

**Known limitation**: role/partition assignment is registration-order based.
After a full-cluster restart, the first pod to register becomes P0 master,
regardless of which partition's data its checkpoint holds. Restoring a
multi-partition cluster naively can therefore assign a pod carrying P1 data
to the P0 slot; key lookups then miss, and a subsequent `orphan_purge` would
**delete** the "misplaced" data.

Partition bindings (see "Restore provenance") now refuse a copy of another
partition / routing layout as a master, but they do not CHOOSE the right pod
for each partition: registration order still assigns partitions. Multi-
partition restore therefore stays manual:

1. Restore all pods from same-timestamp checkpoints (markers on every pod),
   delete all pods together.
2. **Do NOT run orphan_scan/orphan_purge yet.**
3. Compare each pod's assignment (`node sync` via the operator, or the
   `<cluster>-node-map` ConfigMap) with the data it holds (sample keys of
   each partition range against each pod).
4. If assignments don't match the data, delete the mis-assigned pods in an
   order that lets registration order match the data (or repeat until they
   line up), or restore into a fresh cluster and re-drive traffic.
5. Only after verifying every partition serves its own keys: re-enable
   traffic, then orphan scan/purge.

## Automated bootstrap-from-backup (`cluster.backupBootstrap`)

For **replicas=1** (no-slave) clusters, the chart can automate Case A/B: an
init container seeds an EMPTY data dir from `<s3Url>/latest/p0/` before flared
starts, verifies the CURRENT→MANIFEST pair, and refuses (loudly — the pod
stays un-Ready and FlareMasterMissing fires) when the newest backup is older
than `maxAgeSeconds`. It is a strict no-op whenever data exists, so normal
restarts and PVC survivors are untouched.

```yaml
cluster:
  objectStorage:                # shared with cluster.backup — cannot drift
    url: s3://<bucket>/flare-backups
    projectedTokenAudience: sts.amazonaws.com   # keyless web-identity auth
    extraEnv:
      - name: AWS_ROLE_ARN
        value: arn:aws:iam::<acct>:role/<role>
      - name: AWS_WEB_IDENTITY_TOKEN_FILE
        value: /var/run/secrets/sts/token
  backup:
    enabled: true
  backupBootstrap:
    enabled: true
    maxAgeSeconds: 7200         # keep rocksdb walTtlSeconds above interval+this
```

Semantics to be aware of:
- **This is the unplanned-failure path.** RPO = your delta interval, RTO =
  pod reschedule + S3 pull. For PLANNED maintenance (node drains, K8s
  upgrades) add a temporary slave instead (`replicas: 1 -> 2`, wait active,
  do the maintenance, `-> 1`): zero loss, zero downtime, no new K8s node
  needed (soft hostname spread lets the extra pod co-locate).
- Restricted to `partitions=1` (the pod→backup mapping is only well-defined
  there) and requires a data volume (persistence or tmpfs).
- On clusters with live replicas it still behaves correctly (the restored
  data carries the backup's lineage cursor, so reconstruction catches up the
  delta on top) — but a live peer is fresher and usually faster; keep the
  flag for replicas=1 topologies.

## Offline keyspace analysis (`cluster.analysis`)

`flared --analyze-checkpoint <dir>` opens a RocksDB checkpoint READ-ONLY and
streams one CSV row per live key — `key,expire,ttl,size` — to stdout (constant
memory over the cursor; blob-indexed values are dereferenced transparently),
plus a one-line summary (`keys / expired_unreaped / no_expire /
total_value_bytes`) to stderr. Reserved replication keys are excluded.

The `cluster.analysis` CronJob (monthly by default) runs this against the S3
BACKUP checkpoint, never the serving cluster. Because it reads a backup copy,
the expensive full-header scan (every value's header holds expire/size; large
values ≥ min_blob_size are read from blob files) has zero impact on production.
Useful for: expired-but-unreaped counts (reaper health), value-size
distribution (capacity / `min_blob_size` tuning), key inventory, and
cross-checkpoint key-set diffs.

Flow: an init container (`flare-backup`) `aws s3 sync`s each partition's
`latest/pN` to a work volume and makes a per-partition FIFO; then two
CONCURRENT containers stream — `analyze` (flared) gzips
`flared --analyze-checkpoint` into the FIFO, `upload` (flare-backup) drains it
straight into `aws s3 cp -` (multipart from stdin) at
`<url>/<cluster>/analysis/<date>/pN.csv.gz`. The CSV **output is never staged**,
so it stays constant-disk regardless of keyspace size.

**Sizing.** RocksDB can only open a checkpoint from local files, so the pull
stages the WHOLE dataset (SST + blobs — LARGER than the CSV output) to the work
volume. The default is an `emptyDir` on node disk; for big clusters set
`analysis.workVolumeClaimName` to a PVC sized for the dataset. `uploadReport:
false` skips the upload container and FIFO (single `analyze` container, summary
in its log) — no S3 write.

## What backups do NOT cover

- Writes between the last upload and the incident are lost. RPO = the tier-2a
  DELTA interval (hourly by default; tighten to `*/5`/`*/1` — deltas are cheap
  since only new SSTs upload). The daily tier-2b snapshot is for retained
  point-in-time rollback, not RPO. Sub-minute/continuous RPO would need WAL
  archiving to object storage (not implemented; the delta floor is the k8s
  CronJob 1-minute granularity, and at minute-cadence on large data a
  PVC-mounted aws-cli sidecar avoids the per-run intra-cluster checkpoint pull).
- Tier 1 alone does not survive PVC/namespace/cluster loss — enable tier 2.
- The checkpoint contains the replication metadata keys (`__flare_repl_*`);
  after restore the node keeps its lineage token, so WAL sync against peers
  of the same lineage falls back to a full dump when the LSN no longer
  matches — safe, just slower.
