# Flare Operator Quick Start Guide

Get a Flare distributed KVS cluster running on Kubernetes in 5 minutes.

## Prerequisites

- Kubernetes cluster (v1.24+)
- `kubectl` configured
- Docker (for building custom images)

## Step 1: Deploy the Operator

```bash
helm install flare ./helm/flare-operator -n flare-system --create-namespace
```

This creates:
- `flare-system` namespace
- Operator deployment
- Operator service on port 12120

Verify operator is running:

```bash
kubectl get pods -n flare-system
```

Expected output:
```
NAME                              READY   STATUS    RESTARTS   AGE
flare-operator-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

## Step 2: Deploy a Flare Cluster

Create a cluster definition file `cluster.yaml`:

```yaml
apiVersion: flare.gree.net/v1
kind: FlareCluster
metadata:
  name: my-cluster
  namespace: default
spec:
  partitions: 2    # Number of partitions
  replicas: 2      # Replicas per partition (master + slaves)
```

Apply the cluster:

```bash
kubectl apply -f cluster.yaml
```

## Step 3: Verify Cluster is Ready

Wait for all pods to be ready:

```bash
kubectl get pods -l app=flare,cluster=my-cluster
```

Expected output (4 pods for 2 partitions × 2 replicas):
```
NAME                 READY   STATUS    RESTARTS   AGE
my-cluster-nodes-0   1/1     Running   0          1m
my-cluster-nodes-1   1/1     Running   0          1m
my-cluster-nodes-2   1/1     Running   0          1m
my-cluster-nodes-3   1/1     Running   0          1m
```

Check cluster status:

```bash
kubectl get flarecluster my-cluster
```

## Step 4: Test Key Distribution

Connect to any pod to test writes:

```bash
kubectl exec -it my-cluster-nodes-0 -- sh
```

Inside the pod, test setting keys:

```bash
# Set 10 test keys
for i in $(seq 1 10); do
  printf "set key$i 0 0 5\r\nvalue\r\n" | nc localhost 12121
done
```

Expected output:
```
STORED
STORED
STORED
...
```

Check distribution across partitions:

```bash
# Connect to P0 master
printf "stats\r\n" | nc my-cluster-nodes-0 12121 | grep curr_items

# Connect to P1 master
printf "stats\r\n" | nc my-cluster-nodes-1 12121 | grep curr_items
```

Expected output (approximately even distribution):
```
STAT curr_items 5    # P0
STAT curr_items 5    # P1
```

## Step 5: Test Failover

Delete the P0 master pod:

```bash
kubectl delete pod my-cluster-nodes-0
```

Watch for automatic failover:

```bash
kubectl logs -n flare-system deployment/flare-operator --tail=20 --follow
```

Expected logs:
```
[flare-operator] detected 1 dead node(s): [...]
[TRACE] Failover: promoting slave to master for P0
[TopologyBroadcast] Broadcasting node sync v15 (4 nodes) to 3 pods
```

Verify new master is elected:

```bash
kubectl get pods -l app=flare,cluster=my-cluster
```

After ~15 seconds, the deleted pod will restart and rejoin as a slave.

## Advanced Usage

### Scale Up Partitions

Edit the cluster to add a third partition:

```bash
kubectl patch flarecluster my-cluster --type=merge -p '{"spec":{"partitions":3}}'
```

Watch the operator create new pods:

```bash
kubectl get pods -l app=flare,cluster=my-cluster -w
```

### Scale Up Replicas

Add more replicas per partition:

```bash
kubectl patch flarecluster my-cluster --type=merge -p '{"spec":{"replicas":3}}'
```

This adds one more slave per partition.

### View Cluster Topology

The operator maintains cluster state in a ConfigMap:

```bash
kubectl get configmap my-cluster-node-map -o yaml
```

### Monitor Operator Logs

```bash
kubectl logs -n flare-system deployment/flare-operator --tail=100 --follow
```

Key log patterns:
- `[TRACE] Event: NodeAdd` - Node registration
- `[TRACE] Event: NodeState` - State transitions
- `[TopologyBroadcast]` - Topology updates
- `[flare-operator] assigned N proxy nodes` - Role assignments

## Troubleshooting

### Pods Not Starting

Check pod logs:
```bash
kubectl logs my-cluster-nodes-0
```

Common issues:
- Image pull failures
- Resource constraints
- Network policies blocking port 12121

### Keys Not Distributing Evenly

Check operator logs for broadcast confirmations:
```bash
kubectl logs -n flare-system deployment/flare-operator | grep "TcpClient"
```

Expected: `[TcpClient] Sent node sync v10 (4 nodes) to 10.244.x.x:12121`

If missing, check:
- Pods have valid IPs assigned
- No network policies blocking operator → pod:12121
- Operator has network access to pod network

### Failover Not Working

Check dead node detection:
```bash
kubectl logs -n flare-system deployment/flare-operator | grep "dead node"
```

If no dead nodes detected:
- Verify pod actually deleted (`kubectl get pods`)
- Check reconcile loop is running (logs every 5 seconds)
- Verify operator has leader lease (`kubectl get lease -n flare-system`)

### State Stuck in Prepare

Check for NodeState events:
```bash
kubectl logs -n flare-system deployment/flare-operator | grep "NodeState"
```

Expected: `[TRACE] Event: NodeState ... | Result: Prepare->Active`

If missing:
- Check flared pod logs for reconstruction errors
- Verify topology broadcasts are reaching pods
- Check pod:12121 is accessible from operator

## Clean Up

Delete the cluster:

```bash
kubectl delete flarecluster my-cluster
```

This will:
1. Delete all pods
2. Delete services
3. Delete StatefulSet
4. Remove cluster from operator's state

Delete the operator:

```bash
helm uninstall flare -n flare-system
```

## Next Steps

- Read [ARCHITECTURE.md](ARCHITECTURE.md) for technical details
- See [TODO.md](TODO.md) for planned features
- Review [DEBUGGING.md](DEBUGGING.md) for troubleshooting deep dives

## Performance Tuning

### Adjust Reconcile Interval

Edit operator deployment:

```yaml
args: ["--interval", "10"]  # Reconcile every 10 seconds (default: 5)
```

**Trade-off**: Slower failover detection vs lower CPU usage

### Adjust Startup Grace Period

In `Main.lean`, modify `startupGraceCycles`:

```lean
let graceCyclesRef ← IO.mkRef 6  -- 6 * 5s = 30s grace period
```

**Trade-off**: Faster initial deployment vs premature failover during startup

### Resource Limits

For production, add resource limits to operator deployment:

```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "500m"
```

For flared pods, adjust in StatefulSet template (generated by operator):

```yaml
resources:
  requests:
    memory: "512Mi"
    cpu: "500m"
  limits:
    memory: "1Gi"
    cpu: "1000m"
```

## Production Checklist

Before deploying to production:

- [ ] Enable persistent storage for flared pods
- [ ] Configure resource limits for operator and flared
- [ ] Set up monitoring (Prometheus metrics)
- [ ] Configure backup strategy for ConfigMaps
- [ ] Test failover scenarios in staging
- [ ] Document runbooks for common issues
- [ ] Enable leader election (already configured)
- [ ] Configure network policies
- [ ] Set up log aggregation
- [ ] Plan capacity for desired partition/replica count

## Support

For issues or questions:
- Check [DEBUGGING.md](DEBUGGING.md) for common issues
- Review operator logs for detailed error messages
- Open an issue on GitHub with:
  - Kubernetes version
  - Operator logs
  - Cluster manifest
  - Steps to reproduce
