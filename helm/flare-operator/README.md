# Flare Operator Helm Chart

A Kubernetes operator for managing Flare distributed key-value store clusters.

## Features

- **Automatic Topology Management**: The operator maintains optimal data distribution across cluster nodes
- **High Availability**: Supports leader election with multiple operator replicas
- **Cluster Replication**: Built-in support for safe data migration between clusters
- **Partition Reduction Safety**: Prevents unsafe partition reductions that would cause data loss
- **Observability**: Integrated Prometheus metrics and health check endpoints
- **Retry Logic**: Exponential backoff for Kubernetes API resilience

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+

## Installation

### Install the Helm chart

```bash
helm install flare-operator ./helm/flare-operator \
  --namespace flare-system \
  --create-namespace
```

### Install with custom values

```bash
helm install flare-operator ./helm/flare-operator \
  --namespace flare-system \
  --create-namespace \
  --set replicaCount=3 \
  --set image.repository=my-registry/flare-operator \
  --set image.tag=v0.1.0
```

### Install from a values file

```bash
helm install flare-operator ./helm/flare-operator \
  --namespace flare-system \
  --create-namespace \
  --values my-values.yaml
```

## Configuration

The following table lists the configurable parameters of the Flare Operator chart and their default values.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of operator replicas (leader election handles HA) | `2` |
| `image.repository` | Operator image repository | `flare-operator` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `image.tag` | Image tag (defaults to chart appVersion) | `""` |
| `namespace` | Namespace where the operator will run | `flare-system` |
| `clusterName` | Default cluster name to manage | `default` |
| `serviceAccount.create` | Create service account | `true` |
| `serviceAccount.name` | Service account name | `""` (generated) |
| `serviceAccount.annotations` | Service account annotations | `{}` |
| `rbac.create` | Create RBAC resources | `true` |
| `service.type` | Service type | `ClusterIP` |
| `service.port` | Service port for flare index protocol | `12120` |
| `operatorPort` | Operator TCP server port | `12120` |
| `metricsPort` | Prometheus metrics port | `8081` |
| `healthPort` | Health check endpoint port | `8080` |
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `256Mi` |
| `resources.requests.cpu` | CPU request | `100m` |
| `resources.requests.memory` | Memory request | `128Mi` |
| `livenessProbe` | Liveness probe configuration | See values.yaml |
| `readinessProbe` | Readiness probe configuration | See values.yaml |
| `nodeSelector` | Node selector | `{}` |
| `tolerations` | Tolerations | `[]` |
| `affinity` | Affinity rules | `{}` |
| `env` | Additional environment variables | `[]` |
| `extraArgs` | Additional operator arguments | `[]` |

## Creating a Flare Cluster

After installing the operator, you can create a Flare cluster by creating a FlareCluster custom resource:

```yaml
apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: my-flare-cluster
  namespace: default
spec:
  partitions: 4
  replicas: 2
```

This will create a Flare cluster with 4 partitions and 2 replicas per partition (1 master + 1 slave).

### Deploy Flare Nodes

Create a StatefulSet for the Flare nodes:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-flare-cluster-nodes
  namespace: default
spec:
  clusterIP: None
  selector:
    app: flare
    cluster: my-flare-cluster
  ports:
    - port: 12121
      name: flare

---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: my-flare-cluster-nodes
  namespace: default
spec:
  serviceName: my-flare-cluster-nodes
  replicas: 8  # partitions * replicas = 4 * 2
  selector:
    matchLabels:
      app: flare
      cluster: my-flare-cluster
  template:
    metadata:
      labels:
        app: flare
        cluster: my-flare-cluster
    spec:
      containers:
        - name: flared
          image: flare-node:latest
          command:
            - flared
            - --data-dir=/data/flare
            - --server-port=12121
            - --index-server-name=flare-operator.flare-system.svc.cluster.local
            - --index-server-port=12120
          ports:
            - containerPort: 12121
              name: flare
          volumeMounts:
            - name: data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
```

### Using tmpfs for In-Memory Storage

For testing or high-performance scenarios, you can use tmpfs (RAM-based storage) instead of persistent volumes:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-flare-cluster-nodes
  namespace: default
spec:
  clusterIP: None
  selector:
    app: flare
    cluster: my-flare-cluster
  ports:
    - port: 12121
      name: flare

---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: my-flare-cluster-nodes
  namespace: default
spec:
  serviceName: my-flare-cluster-nodes
  replicas: 8  # partitions * replicas = 4 * 2
  selector:
    matchLabels:
      app: flare
      cluster: my-flare-cluster
  template:
    metadata:
      labels:
        app: flare
        cluster: my-flare-cluster
    spec:
      containers:
        - name: flared
          image: flare-node:latest
          command:
            - flared
            - --data-dir=/data/flare
            - --server-port=12121
            - --index-server-name=flare-operator.flare-system.svc.cluster.local
            - --index-server-port=12120
          ports:
            - containerPort: 12121
              name: flare
          volumeMounts:
            - name: tmpfs-data
              mountPath: /data
          resources:
            limits:
              memory: 2Gi  # Ensure sufficient memory for tmpfs
      volumes:
        - name: tmpfs-data
          emptyDir:
            medium: Memory
            sizeLimit: 1Gi  # Limit tmpfs size
```

**Important notes for tmpfs:**
- Data is stored in RAM and will be lost on pod restart
- Suitable for testing, caching, or ephemeral workloads
- Set appropriate memory limits to prevent OOM issues
- `sizeLimit` controls maximum tmpfs size (optional)
- Ensure container memory limits are higher than tmpfs size
```

## Monitoring

### Prometheus Metrics

The operator exposes Prometheus metrics on port 8081 (configurable via `metricsPort`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: flare-operator-metrics
  namespace: flare-system
  labels:
    app: flare-operator
spec:
  ports:
    - name: metrics
      port: 8081
      targetPort: metrics
  selector:
    app.kubernetes.io/name: flare-operator
```

Available metrics:
- `flare_operator_reconcile_duration_seconds` - Histogram of reconcile loop duration
- `flare_operator_dead_nodes_total` - Counter of dead nodes detected
- `flare_operator_topology_broadcasts_total` - Counter of topology broadcasts
- `flare_operator_node_map_version` - Current node map version
- `flare_operator_nodes` - Current number of nodes (by role: master/slave/proxy)

### Health Checks

The operator provides health check endpoints on port 8080:
- `/healthz` - Liveness probe (always returns 200 when operator is running)
- `/readyz` - Readiness probe (returns 200 when operator is ready to serve)

## Cluster Replication

For safe data migration (e.g., reducing partitions), use cluster replication:

```yaml
apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: old-cluster
  namespace: default
spec:
  partitions: 4
  replicas: 2
  clusterReplication:
    enabled: true
    serverName: new-cluster.default.svc.cluster.local
    port: 12121
    mode: duplicate  # or forward
    concurrency: 2
```

See [PARTITION_REDUCTION.md](../../docs/PARTITION_REDUCTION.md) for detailed migration steps.

## Uninstallation

```bash
# Delete all FlareCluster resources first
kubectl delete flareclusters --all --all-namespaces

# Uninstall the Helm release
helm uninstall flare-operator --namespace flare-system

# Optionally delete the CRD (this will delete all FlareCluster resources)
kubectl delete crd flareclusters.flare.gree.net
```

## Troubleshooting

### Check operator logs

```bash
kubectl logs -n flare-system -l app.kubernetes.io/name=flare-operator -f
```

### Check FlareCluster status

```bash
kubectl get flareclusters -A
kubectl describe flarecluster my-flare-cluster -n default
```

### Verify leader election

```bash
kubectl get lease -n flare-system
```

### Check metrics

```bash
kubectl port-forward -n flare-system svc/flare-operator 8081:8081
curl http://localhost:8081/metrics
```

## Development

### Render templates locally

```bash
helm template flare-operator ./helm/flare-operator \
  --namespace flare-system \
  --debug
```

### Lint the chart

```bash
helm lint ./helm/flare-operator
```

### Package the chart

```bash
helm package ./helm/flare-operator
```

## License

See [LICENSE](../../COPYING) file in the repository root.
