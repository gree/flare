# Safe Partition Reduction Guide

## Overview

**IMPORTANT**: Directly reducing the number of partitions in a Flare cluster will cause **DATA LOSS**. The operator automatically detects and blocks unsafe partition reduction attempts.

When you reduce `spec.partitions` in the FlareCluster CRD, the operator will:
- Detect the reduction attempt
- Display a warning message with migration instructions
- **Block** the reduction to prevent data loss
- Continue operating with the current partition count

## Why Direct Reduction Causes Data Loss

Flare uses consistent hashing to distribute keys across partitions. When you reduce the number of partitions:
- Keys mapped to removed partitions become inaccessible
- No automatic data migration occurs
- Existing data in removed partitions is permanently lost

## Safe Migration Using Cluster Replication

The correct approach is to create a new cluster with fewer partitions and migrate data using the cluster replication feature (Blue/Green deployment).

### Step-by-Step Migration Guide

#### Prerequisites
- Existing cluster running with N partitions
- Desire to reduce to M partitions (where M < N)
- Sufficient cluster resources to run both clusters temporarily

#### Step 1: Create New Cluster with Reduced Partitions

Create a new FlareCluster CRD with the desired partition count:

```yaml
apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: my-cluster-new
  namespace: default
spec:
  partitions: 2  # Reduced from 4
  replicas: 2
```

Apply the configuration:

```bash
kubectl apply -f new-cluster.yaml
```

Wait for the new cluster to become ready:

```bash
kubectl get pods -l cluster=my-cluster-new
```

#### Step 2: Enable Cluster Replication

Update the **OLD** cluster to enable replication to the new cluster:

```yaml
apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: my-cluster
  namespace: default
spec:
  partitions: 4  # KEEP ORIGINAL - do not reduce!
  replicas: 2
  clusterReplication:
    enabled: true
    serverName: my-cluster-new-service  # Service name of new cluster
    port: 12121
    mode: duplicate  # Start in duplicate mode
    concurrency: 2
```

Apply the configuration:

```bash
kubectl apply -f old-cluster.yaml
```

#### Step 3: Monitor Migration Progress

The operator automatically manages the migration phases:

```bash
# Check migration status
kubectl get flarecluster my-cluster -o jsonpath='{.status.migrationPhase}'
```

**Migration Phases:**

1. **None** → **Dumping**: Operator configures flared nodes and starts data dump
   - Old cluster writes to both old and new clusters
   - Data syncs from old → new
   - `dump_replication` threads run on master nodes

2. **Dumping** → **Forwarding**: When all data is migrated
   - Operator detects dump completion
   - Switches to forward mode automatically
   - New cluster is now fully synchronized

3. **Forwarding**: Migration complete
   - Old cluster forwards traffic to new cluster
   - Safe to switch applications

**Monitor dump progress:**

```bash
# Check if dump_replication threads are still running
kubectl exec my-cluster-0 -- bash -c "echo 'stats threads' | nc localhost 12121"
```

#### Step 4: Update Application Configuration

Once migration status shows `Forwarding`, update your application to use the new cluster:

**Old service:**
```
my-cluster-service.default.svc.cluster.local:12121
```

**New service:**
```
my-cluster-new-service.default.svc.cluster.local:12121
```

#### Step 5: Verify Data Integrity

Before deleting the old cluster, verify that all data migrated correctly:

```bash
# Connect to old cluster pod
kubectl exec -it my-cluster-0 -- sh
echo "stats" | nc localhost 12121 | grep curr_items

# Connect to new cluster pod
kubectl exec -it my-cluster-new-0 -- sh
echo "stats" | nc localhost 12121 | grep curr_items
```

Compare `curr_items` counts. The new cluster should have all keys from the old cluster.

**Test key retrieval:**

```bash
# Verify a sample of keys exists in new cluster
for i in $(seq 1 100); do
  echo "get key$i" | nc my-cluster-new-service 12121
done
```

#### Step 6: Delete Old Cluster

After confirming data integrity and stable application operation:

```bash
kubectl delete flarecluster my-cluster
```

This will:
- Stop the operator from managing the old cluster
- Delete all old cluster pods
- Remove old cluster services

#### Step 7: Rename New Cluster (Optional)

If you want to use the original cluster name:

```bash
# Export new cluster manifest
kubectl get flarecluster my-cluster-new -o yaml > temp-cluster.yaml

# Edit the manifest to use original name
sed -i 's/my-cluster-new/my-cluster/g' temp-cluster.yaml

# Delete new cluster and recreate with original name
kubectl delete flarecluster my-cluster-new
kubectl apply -f temp-cluster.yaml
```

## Rollback Procedure

If issues occur during migration, you can roll back:

### Before Step 4 (Application Not Switched)

Simply disable cluster replication on the old cluster:

```yaml
spec:
  clusterReplication:
    enabled: false
```

The old cluster continues operating normally.

### After Step 4 (Application Switched)

Switch your application back to the old cluster service and disable replication.

## Troubleshooting

### Migration Stuck in Dumping Phase

**Symptoms:** Migration phase stays at `Dumping` for extended period

**Diagnosis:**
```bash
# Check dump_replication thread status
kubectl exec my-cluster-0 -- bash -c "echo 'stats threads' | nc localhost 12121"
```

**Solutions:**
- Verify network connectivity between clusters
- Check for resource constraints (CPU, memory)
- Review flared logs for errors:
  ```bash
  kubectl logs my-cluster-0
  ```

### Data Count Mismatch

**Symptoms:** `curr_items` differs between old and new clusters

**Diagnosis:**
- Check if dump completed successfully
- Verify no ongoing writes to old cluster during migration
- Check for errors in flared logs

**Solutions:**
- Wait for dump to fully complete
- Restart dump by toggling replication off/on
- Verify key hash algorithm matches between clusters

### Performance Degradation During Migration

**Symptoms:** Slow response times during migration

**Causes:**
- Duplicate writes (writing to both clusters)
- Network bandwidth saturation
- Resource contention

**Solutions:**
- Reduce `concurrency` in replication config
- Schedule migration during low-traffic periods
- Increase resource limits for pods

## Best Practices

1. **Test in Staging First**: Always test the migration procedure in a non-production environment

2. **Schedule During Low Traffic**: Minimize impact by migrating during maintenance windows

3. **Monitor Continuously**: Watch metrics and logs throughout the migration

4. **Verify Before Deletion**: Always confirm data integrity before deleting the old cluster

5. **Keep Backups**: Ensure you have backups before starting the migration

6. **Document Configuration**: Record old cluster configuration for rollback

## Frequently Asked Questions

### Can I reduce partitions without creating a new cluster?

No. Direct partition reduction will cause data loss. You must use the cluster replication approach.

### How long does migration take?

Migration time depends on:
- Amount of data (curr_items count)
- Network bandwidth
- Replication concurrency setting
- Cluster load

Typical migration: 100,000 keys ≈ 5-10 minutes

### Can I reduce by more than one partition at a time?

Yes. You can reduce from N partitions to any M partitions (M < N) in a single migration.

### What happens if the operator crashes during migration?

The migration state is persisted in the CRD status. When the operator restarts, it resumes from the current phase.

### Can I scale up partitions safely?

Yes! Scaling up (increasing partitions) is safe and automatic. Just increase `spec.partitions` in the CRD.

## See Also

- [Cluster Replication Documentation](./CLUSTER_REPLICATION.md)
- [Flare Operator README](./README.md)
- [TODO & Future Improvements](./TODO.md)
