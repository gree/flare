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
- `deploy/backup-cronjob.yaml` — daily trigger (busybox + nc over the
  headless-service pod DNS) and an optional suspended S3-upload CronJob.
- Restore hook in the StatefulSet startup command (PVC deployments): if
  `<data-dir>/RESTORE` exists, its content names a checkpoint directory; the
  live DB is replaced by it and the marker consumed before flared starts.

## Taking a backup

Automatic: enable the `flare-backup` CronJob (adjust `NUM_PODS`, schedule).

Manual (one pod):

```
printf 'backup manual-20260713\r\n' | nc <pod-ip> 12121
```

Backups are **per pod**: each pod checkpoints its own DB. For a full-cluster
restore point, back up all pods at (approximately) the same time — the
CronJob does this. Cross-pod consistency is *not* atomic: pods are
checkpointed seconds apart. For a KVS this is normally acceptable; if you
need a hard cut, quiesce writes first.

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

### Case B — restore from S3 (PVC also lost)

1. Provision the new PVC/pod (StatefulSet recreates it empty).
2. Download and unpack into the pod:
   ```
   aws s3 cp s3://bucket/…/<pod>-<name>.tar.gz - | \
     kubectl exec -i <pod> -- tar xzf - -C /data/flare/backups
   ```
3. Continue with Case A steps 2–4.

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

## What backups do NOT cover

- Writes between the last checkpoint and the incident are lost (RPO = backup
  interval). Reduce the CronJob interval if that matters.
- Tier 1 alone does not survive PVC/namespace/cluster loss — enable tier 2.
- The checkpoint contains the replication metadata keys (`__flare_repl_*`);
  after restore the node keeps its lineage token, so WAL sync against peers
  of the same lineage falls back to a full dump when the LSN no longer
  matches — safe, just slower.
