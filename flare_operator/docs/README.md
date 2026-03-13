# Flare Operator - Kubernetes Native Distributed KVS

A Kubernetes operator written in Lean 4 that replaces the original C++ `flarei` coordinator for managing Flare distributed key-value store clusters.

## Current Status

✅ **FULLY OPERATIONAL** - All core features working as of commit `a9ef225`

### Test Results

```
# Failover Test
✓ Wrote via proxy: stored 100/100
✓ Distribution: P0=52, P1=48, total=100
✓ Failover: new master elected
✓ Data preserved: P1 curr_items=48 maintained
✓ Recovery: all pods ready, topology intact

# Scale-out Master Test
✓ Wrote via proxy: stored 100/100
✓ Distribution: P0=51, P1=49, total=100
✓ Scale-out: P2=37 after adding third partition

# Scale-out Slave Test
✓ Wrote via proxy: stored 100/100
✓ Distribution: P0=56, P1=44, total=100
✓ Slaves: P0=2, P1=2 (correct replica count)
```

## Features

- **Automatic Failover**: Detects dead nodes and promotes slaves to masters
- **Even Key Distribution**: Hash-based routing with P0≈50%, P1≈50% distribution
- **State Machine Verification**: Pure functional reconciliation with Lean proofs
- **Native Topology Broadcast**: Active TCP push to flared nodes (matches C++ flarei)
- **Hybrid Role Assignment**: P0 immediate, P1+ via role transition triggers

## Architecture Highlights

### Communication Model

**Correct (Implemented)**:
- **Node → Operator (12120)**: flared connects, sends commands (node add, node state), receives response
- **Operator → Node (12121)**: Operator actively connects to each flared's listening port and pushes topology updates

**Previous (Incorrect)**:
- Operator tried to push through same socket on port 12120 ❌

### State Transition Flow

1. **Pod starts** → flared connects to operator:12120
2. **NodeAdd** → Operator registers node as Proxy (P0 Master assigned immediately)
3. **Reconcile loop** → Operator assigns P1+ Masters from Proxy pool
4. **nodeMapVersion increments** → Operator broadcasts topology to all pods:12121
5. **flared receives broadcast** → Detects Proxy→Master transition, calls `_shift_node_role()`
6. **Reconstruction thread starts** → P1 Master syncs data from P0 Master
7. **Reconstruction completes** → flared sends "node state ready" to operator:12120
8. **Operator promotes to Active** → Broadcasts final topology
9. **Proxies route evenly** → Keys distributed across P0≈50%, P1≈50%

## Key Components

### Core Modules

- **`Main.lean`**: Operator entry point, reconcile loop, leader election
- **`Reconciler.lean`**: Pure state machine for cluster topology management
- **`TcpServer.lean`**: TCP server on port 12120 for flarei text protocol
- **`TcpClient.lean`**: Outbound TCP client for connecting to flared:12121
- **`TopologyBroadcast.lean`**: Orchestrates topology broadcasts to all pods
- **`Protocol.lean`**: Flare text protocol parser/serializer
- **`FlareCluster.lean`**: Core data structures and CRD definitions
- **`Bridge.lean`**: Kubernetes API integration via kubectl

### Critical Fixes

#### 1. Topology Broadcast Architecture

**Problem**: Operator tried to push topology through same socket nodes used to connect (port 12120).

**Solution**: Implement active TCP connections from operator to each flared node's port 12121, matching C++ flarei's `queue_node_sync` behavior.

**Files**: `TcpClient.lean`, `TopologyBroadcast.lean`, `Main.lean`

#### 2. State Machine Integration

**Problem**: Immediate role assignment prevented flared from detecting role transitions, so reconstruction threads never started.

**Solution**: Register nodes as Proxy initially, then assign roles via reconcile loop. When flared receives topology broadcast showing role change, it triggers `_shift_node_role()` and spawns reconstruction.

**Files**: `Reconciler.lean` (NodeAdd handler), `Main.lean` (assignProxies)

#### 3. Partition-Size Semantics

**Problem**: `partition-size=2` (partition count) caused out-of-bounds array access when flared tried to read `_map[2]` after P1 became Active.

**Solution**: Keep `partition-size=1024` (max ring size for consistent hashing). C++ flared allocates array using this size, then indexes it with actual partition count.

**Files**: `Reconciler.lean` (removed partitionSize override)

## Usage

### Deploy Operator

```bash
kubectl apply -f deploy/operator.yaml
```

### Deploy Flare Cluster

```yaml
apiVersion: flare.gree.net/v1
kind: FlareCluster
metadata:
  name: my-cluster
  namespace: default
spec:
  partitions: 2
  replicas: 2
```

```bash
kubectl apply -f cluster.yaml
```

### Verify Distribution

```bash
# Connect to any flared pod
kubectl exec -it <pod-name> -- sh

# Test key distribution
for i in $(seq 1 100); do
  echo "set key$i 0 0 5\r\nvalue\r\n" | nc localhost 12121
done

# Check stats
echo "stats" | nc localhost 12121 | grep curr_items
```

## Development

### Build

```bash
cd flare_operator
lake build FlareOperator.Main
```

### Run E2E Tests

```bash
cd flare_operator
.lake/build/bin/flare_e2e
```

### Test Specific Suite

```bash
.lake/build/bin/flare_e2e --filter failover
```

## References

- Original Flare: https://github.com/gree/flare
- Lean 4: https://lean-lang.org/
- Kubernetes Operators: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
