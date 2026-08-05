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
- Restore hook in the StatefulSet startup command (PVC deployments): if
  `<data-dir>/RESTORE` exists, its content names a checkpoint directory; the
  live DB is replaced by it and the marker consumed before flared starts.

## Taking a backup

Automatic: set `cluster.objectStorage.url` and `cluster.backup.enabled: true`
(adjust `backup.role`, `backup.schedule`, `backup.keepDays`).

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

### Case A — single-partition cluster (partitions=1): fully supported, e2e-tested

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
   in; the operator re-elects a master. Verify with key sampling before
   re-enabling traffic.

This flow is exercised end-to-end by the `backup-restore` e2e suite
(write → checkpoint → flush_all on all replicas → marker → pod deletion →
per-key exact-value verification).

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

### Case C — multi-partition cluster: MANUAL, read this first

**Known limitation**: role/partition assignment is registration-order based.
After a full-cluster restart, the first pod to register becomes P0 master,
regardless of which partition's data its checkpoint holds. Restoring a
multi-partition cluster naively can therefore assign a pod carrying P1 data
to the P0 slot; key lookups then miss, and a subsequent `orphan_purge` would
**delete** the "misplaced" data.

Until partition pinning is implemented (operator reading a partition marker
from restored data — future work), multi-partition restore must be manual:

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
