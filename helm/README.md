# Flare Operator Helm Charts

This directory contains Helm charts for deploying the Flare Operator on Kubernetes.

## Available Charts

### flare-operator

The main Helm chart for deploying the Flare Operator, which manages Flare distributed key-value store clusters on Kubernetes.

**Features:**
- Automatic topology management
- High availability with leader election
- Cluster replication support
- Partition reduction safety
- Prometheus metrics integration
- Health check endpoints

## Quick Start

### Prerequisites

- Kubernetes 1.19+
- Helm 3.0+

### Install the Operator

```bash
# Install with default values
helm install flare-operator ./flare-operator \
  --namespace flare-system \
  --create-namespace

# Or install with custom values
helm install flare-operator ./flare-operator \
  --namespace flare-system \
  --create-namespace \
  --values ./flare-operator/values-production.yaml
```

### Verify Installation

```bash
# Check operator deployment
kubectl get deployment -n flare-system

# Check operator logs
kubectl logs -n flare-system -l app.kubernetes.io/name=flare-operator -f
```

### Create a Flare Cluster

```bash
kubectl apply -f - <<EOF
apiVersion: flare.gree.net/v1alpha1
kind: FlareCluster
metadata:
  name: my-cluster
  namespace: default
spec:
  partitions: 4
  replicas: 2
EOF
```

## Documentation

For detailed configuration options and usage, see the [flare-operator chart README](./flare-operator/README.md).

## Upgrading

```bash
# Upgrade to new version
helm upgrade flare-operator ./flare-operator \
  --namespace flare-system \
  --values your-values.yaml
```

## Uninstalling

```bash
# Delete all FlareCluster resources first
kubectl delete flareclusters --all --all-namespaces

# Uninstall the operator
helm uninstall flare-operator --namespace flare-system
```

## Development

### Lint Charts

```bash
helm lint ./flare-operator
```

### Render Templates

```bash
helm template flare-operator ./flare-operator \
  --namespace flare-system \
  --debug
```

### Package Chart

```bash
helm package ./flare-operator
```

This creates a `.tgz` archive that can be published to a chart repository.
