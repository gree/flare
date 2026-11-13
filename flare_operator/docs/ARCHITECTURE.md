# Flare Operator Architecture

This document describes the technical architecture of the Lean 4 Flare Operator.

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                       │
│                                                               │
│  ┌─────────────────┐         ┌─────────────────────────┐   │
│  │ Flare Operator  │         │ FlareCluster CRD        │   │
│  │  (Lean 4)       │◄────────│ partitions: 2           │   │
│  │                 │         │ replicas: 2             │   │
│  │  Port 12120 ◄───┼─────────┤ Total: 4 pods           │   │
│  │  (Inbound)      │         └─────────────────────────┘   │
│  │                 │                                         │
│  │  Port 12121 ────┼────────┐                               │
│  │  (Outbound)     │        │                               │
│  └────────┬────────┘        │                               │
│           │                 │                               │
│           │ Active Push     │                               │
│           ▼                 ▼                               │
│  ┌─────────────────┐  ┌─────────────────┐                 │
│  │ flared Pod 0    │  │ flared Pod 1    │                 │
│  │ P0 Master       │  │ P1 Master       │                 │
│  │ Port 12121      │  │ Port 12121      │                 │
│  │ (Listening)     │  │ (Listening)     │                 │
│  └─────────────────┘  └─────────────────┘                 │
│  ┌─────────────────┐  ┌─────────────────┐                 │
│  │ flared Pod 2    │  │ flared Pod 3    │                 │
│  │ P0 Slave        │  │ P1 Slave        │                 │
│  │ Port 12121      │  │ Port 12121      │                 │
│  └─────────────────┘  └─────────────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

## Communication Protocols

### Inbound: flared → Operator (Port 12120)

**Purpose**: Node registration, state updates, metadata queries

**Protocol**: Flare text protocol (newline-delimited commands)

**Connection Pattern**:
- flared initiates connection
- Sends command
- Receives response
- May keep connection alive for multiple commands

**Key Commands**:
```
node add <fqdn> <port>\r\n
→ NODE <name> <port> <role> <state> <partition> <balance> <thread>\r\n
  NODE ...\r\n
  END\r\n

meta\r\n
→ META partition-size 1024\r\n
  META key-hash-algorithm jenkins\r\n
  META partition-type modular\r\n
  META partition-modular-hint 1\r\n
  META partition-modular-virtual 4096\r\n
  END\r\n

node state <fqdn> <port> ready\r\n
→ OK\r\n
```

**Implementation**: `TcpServer.lean`

### Outbound: Operator → flared (Port 12121)

**Purpose**: Topology broadcast when cluster state changes

**Protocol**: Flare text protocol

**Connection Pattern**:
- Operator initiates connection
- Sends `node sync <version>` command
- Sends full node list
- Closes connection

**Key Commands**:
```
node sync <version>\r\n
NODE <name> <port> <role> <state> <partition> <balance> <thread>\r\n
NODE ...\r\n
END\r\n
```

**Implementation**: `TcpClient.lean`, `TopologyBroadcast.lean`

**Trigger**: When `nodeMapVersion` increments in `Main.lean` reconcile loop

## State Machine

### FlareClusterState

Core data structure representing cluster topology:

```lean
structure FlareClusterState where
  nodeMap : List (String × FlareNode)      -- All registered nodes
  partitionMap : List FlarePartition        -- Partition master/slave assignments
  nodeMapVersion : Nat                      -- Increments on topology changes
  partitionSize : Nat                       -- Max ring size (default 1024)
  keyHashAlgorithm : String                 -- Hash algorithm (jenkins)
```

### FlareNode

```lean
structure FlareNode where
  serverName : String                       -- FQDN or IP
  serverPort : Nat                          -- Port (12121)
  role : FlareRole                          -- Master, Slave, or Proxy
  state : FlareState                        -- Active, Prepare, Down
  partition : Int                           -- Partition index (-1 for Proxy)
  balance : Nat                             -- Load balancing weight (100)
  threadType : Nat                          -- Thread count (16)
```

### State Transitions

```
┌─────────┐
│ Proxy   │ ◄─── Initial registration (NodeAdd)
│ p=-1    │
└────┬────┘
     │ Reconcile loop assigns role
     │ (assignProxies in Main.lean)
     ▼
┌─────────┐      Topology Broadcast        ┌──────────────┐
│ Master  │      (Operator → flared:12121)  │ flared       │
│ Prepare │ ────────────────────────────────→│ detects role │
│ p=1     │                                  │ transition   │
└────┬────┘                                  └──────┬───────┘
     │                                              │
     │                                              │ _shift_node_role()
     │                                              │ spawn reconstruction
     │                                              ▼
     │                                       ┌──────────────┐
     │       node state ready                │ Sync from P0 │
     │ ◄─────────────────────────────────────│ Complete     │
     │       (flared → Operator:12120)       └──────────────┘
     ▼
┌─────────┐
│ Master  │
│ Active  │
│ p=1     │
└─────────┘
```

## Reconciliation Loop

**Location**: `Main.lean::reconcileOnce`

**Frequency**: Every 5 seconds (configurable)

**Steps**:

1. **Fetch CRD Spec** → Get desired partitions/replicas from Kubernetes
2. **List Live Pods** → Query K8s for pod IPs and readiness
3. **Detect Dead Nodes** → Compare cluster state with live pods
4. **Handle Failover** → Promote slaves to masters for dead partitions
5. **Assign Proxies** → Convert Proxy nodes to Master/Slave based on needs
6. **Broadcast Topology** → If `nodeMapVersion` changed, push to all pods
7. **Update ConfigMap** → Write cluster state for observability
8. **Service Routing** → Patch K8s Services to point to active masters

### assignProxies Logic

```lean
private def assignProxies (state : FlareClusterState) (crd : FlareClusterView) : FlareClusterState :=
  state.nodeMap.foldl (init := state) fun currentState (nodeKey, node) =>
    if node.role == FlareRole.Proxy then
      let (newState, _) := autoAssign currentState crd nodeKey node
      newState
    else
      currentState
```

**Effect**: Triggers `nodeMapVersion` increment → Topology broadcast → flared role transition → Reconstruction

## autoAssign Algorithm

**Location**: `Reconciler.lean::autoAssign`

**Purpose**: Assign optimal role to a node based on cluster needs

**Priority**:
1. **Master** if partition needs one
2. **Slave** if partition needs replica
3. **Proxy** if all positions filled

**Master Assignment Logic**:

```lean
-- P0 Master: Always Active (source of truth, no reconstruction)
if pIdx == 0 then
  state := Active
else
  -- P1+ Masters: Start Prepare (must reconstruct from P0)
  state := Prepare
```

**Slave Assignment**: Always `Prepare` (must sync from master)

## Partition-Size Semantics

**Critical**: `partition-size` is **NOT** the current partition count!

### C++ Implementation (key_resolver_modular.cc)

```cpp
// Constructor allocates 2D array
this->_map = new int*[this->_partition_size];  // partition_size = 1024
for (int i = 0; i < this->_partition_size; i++) {
    this->_map[i] = new int[this->_virtual];   // virtual = 4096
}

// Resolve function indexes by actual partition count
int key_resolver_modular::resolve(int key_hash_value, int partition_size) {
    // partition_size here is the CURRENT partition count (e.g., 2)
    return this->_map[partition_size][...];  // Accesses _map[2]
}
```

### The Bug (Fixed)

**Before**:
```lean
let state := { state with partitionSize := crd.spec.partitions }  -- ❌ Sets to 2
```
- Operator sends `META partition-size 2`
- flared allocates `_map` with size 2 (indices 0, 1)
- When P1 activates, `partition_size=2` → accesses `_map[2]` → **Out of bounds!**

**After**:
```lean
-- Keep default partitionSize = 1024 (max ring size)
```
- Operator sends `META partition-size 1024`
- flared allocates `_map` with size 1024
- When P1 activates, `partition_size=2` → accesses `_map[2]` → ✅ Valid

## Data Structures

### Partition Map

```lean
structure FlarePartition where
  master : Option String        -- Node key of master (if assigned)
  slaves : List String          -- Node keys of slaves
```

**Example** (2 partitions, 2 replicas):
```
partitionMap = [
  { master = "node-0:12121", slaves = ["node-2:12121"] },  -- P0
  { master = "node-1:12121", slaves = ["node-3:12121"] }   -- P1
]
```

### Node Map

```lean
nodeMap : List (String × FlareNode)
```

**Example**:
```
[
  ("node-0:12121", {role=Master, state=Active, partition=0, ...}),
  ("node-1:12121", {role=Master, state=Active, partition=1, ...}),
  ("node-2:12121", {role=Slave, state=Prepare, partition=0, ...}),
  ("node-3:12121", {role=Slave, state=Prepare, partition=1, ...})
]
```

## Topology Broadcast Flow

1. **Trigger**: `nodeMapVersion` increments in reconcile loop
2. **Get Pods**: Query K8s for current pod IPs via `listFlaredPods`
3. **For each pod**:
   - Connect to `podIP:12121`
   - Send `node sync <version>\r\n`
   - Send full node list (NODE commands)
   - Send `END\r\n`
   - Close connection
4. **flared Processing**:
   - Receives broadcast on port 12121
   - Parses node list
   - Calls `reconstruct_node()`
   - Detects role change → Pushes to `shift_role_stack`
   - `_shift_node_role()` spawns reconstruction thread if needed

## Leader Election

**Mechanism**: Kubernetes Lease API

**Lease Name**: `<cluster-name>-operator-lease`

**Duration**: 15 seconds

**Process**:
1. Operator attempts to acquire lease on startup
2. If acquired → Enter leader mode, start TCP server
3. Renew lease every 5 seconds (reconcile loop)
4. If renewal fails → Exit (K8s will restart pod)

**Implementation**: `Main.lean::tryAcquireOrRenew`

## Error Handling

### Dead Node Detection

```lean
def detectDeadNodes (state : FlareClusterState) (pods : List PodInfo) : List String :=
  let livePodKeys := pods.map (·.toNodeKey)
  state.nodeMap.filterMap fun (nodeKey, node) =>
    if node.role != FlareRole.Proxy && !livePodKeys.contains nodeKey then
      some nodeKey
    else
      none
```

### Failover

```lean
def handleFailover (state : FlareClusterState) (deadKeys : List String) : FlareClusterState × List String :=
  deadKeys.foldl (init := (state, [])) fun (currentState, logs) deadKey =>
    match currentState.lookupNode deadKey with
    | some deadNode =>
      if deadNode.role == FlareRole.Master then
        promoteSlaveToMaster currentState deadNode.partition
      else
        (currentState.removeNode deadKey, logs ++ ["removed slave"])
    | none => (currentState, logs)
```

## Performance Characteristics

- **Reconcile Loop**: O(n) where n = number of nodes
- **Dead Detection**: O(n × m) where m = number of pods
- **Topology Broadcast**: O(p) where p = number of pods (sequential)
- **State Lookups**: O(n) (linear search in List)

**Future Optimization**: Replace `List` with `RBMap` for O(log n) lookups

## Security

- **Leader Election**: Prevents split-brain scenarios
- **Read-Only CRD**: TCP server cannot mutate cluster via protocol
- **No Direct kubectl**: All K8s operations via typed Bridge API
- **Sandboxed Testing**: E2E tests use isolated namespaces

## Observability

### ConfigMap

**Name**: `<cluster-name>-node-map`

**Content**: JSON representation of `FlareClusterState`

**Update Frequency**: Every reconcile loop

### Logs

**Trace Events**:
- `[TRACE] Event: NodeAdd <key> | Result: Master P0 (Active)`
- `[TRACE] Event: NodeState <key> | Result: Prepare->Active`
- `[TRACE] Failover: processed 1 dead nodes`

**Broadcast Logs**:
- `[TopologyBroadcast] Broadcasting node sync v10 (4 nodes) to 4 pods`
- `[TcpClient] Sent node sync v10 (4 nodes) to 10.244.0.14:12121`

### Metrics (Future)

Planned Prometheus metrics:
- `flare_operator_reconcile_duration_seconds`
- `flare_operator_node_map_version`
- `flare_operator_dead_nodes_detected_total`
- `flare_operator_topology_broadcasts_total`
