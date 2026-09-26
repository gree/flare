# Debugging Journey: Key Distribution Fix

This document chronicles the debugging process that led to fixing the key distribution issue in the Flare Operator.

## The Problem

**Symptom**: All 100 test keys routed to P0, zero keys routed to P1

```
# Distribution: P0=100, P1=0, total=100
```

**Expected**: Even distribution across partitions (P0≈50, P1≈50)

## Investigation Timeline

### Phase 1: Initial Hypothesis - Routing Configuration

**Theory**: Hash algorithm or partition configuration incorrect

**Investigation**:
- Verified `META` response returns `jenkins` hash algorithm ✓
- Verified `partition-type modular` ✓
- Verified `partition-modular-hint 1` ✓
- Verified `partition-modular-virtual 4096` ✓

**Result**: Configuration correct, issue elsewhere

### Phase 2: Master State Analysis

**Theory**: P1 Master not in Active state

**Investigation**:
```bash
kubectl logs deployment/flare-operator | grep "Master P1"
```

**Finding**: P1 Master stuck in `Prepare` state while P0 Master was `Active`

**Why This Matters**: In Flare, only `Active` masters accept writes. Proxies route keys only to `Active` masters. If P1 is `Prepare`, all keys route to P0.

### Phase 3: State Transition Expectations

**Theory**: P1 Master should auto-transition from `Prepare` to `Active`

**C++ Code Analysis** (`src/lib/cluster.cc:1010`):
```cpp
// Masters
n.node_state = preparing ? (node_partition == 0 ? state_active : state_prepare) : state_active;
```

**Discovery**: Original C++ flarei assigns:
- P0 Master: `Active` (special case, source of truth)
- P1+ Masters: `Prepare` (must reconstruct data from P0)

**Expected Flow**:
1. P1 Master starts as `Prepare`
2. Reconstruction thread syncs data from P0
3. flared sends `node state ready` to operator
4. Operator promotes P1 to `Active`

### Phase 4: Missing State Transitions

**Investigation**: Search operator logs for `NodeState` events

```bash
kubectl logs deployment/flare-operator | grep "NodeState"
```

**Result**: **Zero NodeState events!**

**Critical Discovery**: C++ flared nodes were NOT sending `node state` commands to the operator.

### Phase 5: Root Cause Analysis - Communication Architecture

**Initial Theory**: flared doesn't send state transitions when talking to operator (only to flarei)

**C++ Code Analysis** (`src/lib/cluster.cc::activate_node()`):
```cpp
// This method DOES send "node state" commands!
shared_connection c = this->_thread_pool->get_connection(
    this->_index_server_name, this->_index_server_port);
op_node_state* p = new op_node_state(c, this->_node_server_name,
    this->_node_server_port, this->_node_state);
```

**Correction**: flared DOES send state commands, but only when reconstruction completes.

**New Theory**: Reconstruction thread never starting in the first place.

### Phase 6: Reconstruction Thread Analysis

**C++ Code Analysis** (`src/lib/cluster.cc::_shift_node_role()`):
```cpp
void cluster::_shift_node_role() {
    // Pops from shift_role_stack and spawns reconstruction thread
    handler_reconstruction* hr = new handler_reconstruction(this, ...);
    this->_thread_pool->dispatch(hr);
}
```

**Trigger Condition**: `shift_role_stack` must have entries pushed to it.

**When Does This Happen?** (`src/lib/cluster.cc::reconstruct_node()`):
```cpp
// If role changed from existing state
if (r.node_role != p->second.node_role) {
    this->_shift_role_stack.push(r);
}
```

**Critical Insight**: Reconstruction only triggers when flared **witnesses a role transition** by comparing old vs new topology.

### Phase 7: The Missing Transition

**Analysis**: In Lean operator's `NodeAdd` handler, nodes were immediately assigned as `Master` or `Slave`:

```lean
| .NodeAdd serverName serverPort =>
    let (newState, _) := autoAssign state crd nodeKey newNode
    -- Returns node already as Master/Slave
```

**Problem**: When flared receives this response:
1. `_node_map` is initially empty (fresh start)
2. `reconstruct_node()` sees a "new node", not a "role transition"
3. `shift_role_stack` remains empty
4. Reconstruction thread never spawns
5. `node state ready` never sent
6. P1 stuck in `Prepare` forever

### Phase 8: Topology Broadcast Architecture

**User Insight**: The communication direction was backwards!

**Wrong Assumption**: Operator should push topology through the same socket flared used to connect (port 12120)

**Correct Architecture** (from C++ `src/lib/queue_node_sync.cc`):
```cpp
// flarei actively connects to each flared node's listening port
client->connect(host, port, use_keepalive, connection_pool_timeout);
```

**Discovery**: Operator must:
1. Accept connections from flared on port 12120 (for registration)
2. **Actively connect** to each flared's port 12121 (for topology broadcast)

This matches the original flarei coordinator behavior.

### Phase 9: Solution Design - Proxy Registration + Role Assignment

**Strategy**: Split registration from role assignment

**Implementation**:

1. **NodeAdd**: Register node as `Proxy` only
   ```lean
   | .NodeAdd serverName serverPort =>
       let newNode := { role := FlareRole.Proxy, ... }
       let newState := state.addNode nodeKey newNode
   ```

2. **Reconcile Loop**: Assign roles from Proxy pool
   ```lean
   let stateAfterAssignment := assignProxies currentState crd
   ```

3. **Topology Broadcast**: When `nodeMapVersion` changes, actively push to all pods:12121
   ```lean
   if finalVersion != oldVersion then
       broadcastTopologyToAllPods crName ns finalVersion finalState.getNodes
   ```

**Flow**:
```
Pod starts → NodeAdd (Proxy) → Reconcile assigns Master
→ nodeMapVersion++ → Broadcast to pod:12121
→ flared sees Proxy→Master transition → _shift_node_role()
→ Reconstruction thread starts → Syncs from P0
→ Sends "node state ready" → Operator promotes to Active
→ Broadcast final topology → Even key distribution!
```

### Phase 10: Implementation & First Test

**Result**: NodeState events appearing in logs! ✓

```
[TRACE] Event: NodeState ...nodes-1... | Result: Prepare->Active | Reason: reconstruction complete
[TRACE] Event: NodeState ...nodes-2... | Result: Prepare->Active | Reason: reconstruction complete
```

**But**: Still `Distribution: P0=0, P1=0, total=0` (all writes failing!)

### Phase 11: P0 Master Reconstruction Bug

**Investigation**: Why is P0 Master trying to reconstruct?

**Log Evidence**:
```
[TRACE] Event: NodeState nodes-0... | Result: rejected | Reason: node state: transition 0→3 not allowed
```

Translation: `state 0=Active`, `state 3=Ready`. P0 Master is already Active but trying to transition to Ready!

**Root Cause**: P0 Master was being assigned via Proxy→Master flow, which triggered reconstruction. But P0 is the **source of truth** - it should never reconstruct!

**Fix**: Hybrid approach
- P0 Master: Assign immediately during `NodeAdd` (no role transition, no reconstruction)
- P1+ Masters: Assign via reconcile loop (triggers role transition and reconstruction)

```lean
if needsP0Master && numPartitions > 0 then
    let (newState, assignedNode) := autoAssign state crd nodeKey newNode
    if assignedNode.partition == 0 then
        -- P0 Master assigned immediately
        (newState, .End ...)
```

### Phase 12: Partition-Size Out-of-Bounds Bug

**Result After Hybrid Fix**: Still `Distribution: P0=0, P1=0, total=0`

**User Insight**: Out-of-bounds array access!

**C++ Code Analysis** (`src/lib/key_resolver_modular.cc`):
```cpp
// Constructor
this->_map = new int*[this->_partition_size];  // Allocates array

// Resolve function
int key_resolver_modular::resolve(int key_hash_value, int partition_size) {
    return this->_map[partition_size][...];  // Indexes by partition COUNT
}
```

**The Bug**:
```lean
-- In reconcileStep:
let state := { state with partitionSize := crd.spec.partitions }  -- ❌ Sets to 2
```

**What Happens**:
1. Operator sends `META partition-size 2`
2. flared allocates `_map[2]` (indices 0, 1)
3. When P1 activates, partition count = 2
4. `resolve()` accesses `_map[2]` → **Out of bounds!**
5. Reads garbage memory → Routing fails → Writes rejected

**The Fix**:
```lean
-- Remove the override, keep default partitionSize = 1024
-- Do NOT: let state := { state with partitionSize := crd.spec.partitions }
```

**Result**: `META partition-size 1024` sent to flared

**What Happens**:
1. flared allocates `_map[1024]` (indices 0..1023)
2. When P1 activates, partition count = 2
3. `resolve()` accesses `_map[2]` → ✓ Valid index!
4. Correct routing → Even key distribution!

## The Final Fix

**Three Interconnected Bugs**:

1. **Communication Architecture**: Operator must actively connect to flared:12121 for broadcasts
2. **State Machine Trigger**: Proxy→Master transition triggers reconstruction thread
3. **Partition-Size Semantics**: Must be max ring size (1024), not partition count (2)

**Result**:
```
# Distribution: P0=52, P1=48, total=100
```

Perfect! 🎉

## Lessons Learned

### 1. Read the Original Source Code

The C++ implementation contained critical architectural details:
- Communication patterns (inbound vs outbound)
- State machine triggers (`_shift_node_role`)
- Array allocation semantics (`partition_size` vs partition count)

**Without reading the C++ code**, we could not have discovered these subtle bugs.

### 2. Terminology Matters

`partition-size` has a **completely different meaning** in the C++ implementation than expected:
- **Not**: Current partition count (e.g., 2)
- **Actually**: Maximum consistent hashing ring size (1024)

This single terminology confusion caused out-of-bounds memory access.

### 3. State Transitions Require Triggers

In distributed systems, passive waiting is often insufficient. The C++ flared nodes needed to **witness** a role change to trigger reconstruction.

**Design Principle**: Ensure state machines have clear transition triggers, not just final states.

### 4. Communication Direction Is Critical

The direction of TCP connections matters:
- Inbound (passive): Node → Operator for registration
- Outbound (active): Operator → Node for topology broadcast

Trying to reuse inbound connections for outbound broadcasts violated the protocol architecture.

### 5. Layered Debugging

Effective debugging required working through multiple layers:
1. **Application Layer**: Key distribution
2. **State Layer**: Master Active/Prepare states
3. **Protocol Layer**: NodeState commands
4. **Implementation Layer**: Reconstruction threads
5. **Memory Layer**: Array bounds

Each layer revealed a different piece of the puzzle.

### 6. Trust But Verify Assumptions

Initial assumption: "flared doesn't send state transitions to operator"
Reality: "flared sends transitions, but only when reconstruction triggers"

Always verify assumptions against source code, not just observed behavior.

## Debugging Tools Used

### 1. Operator Logs

```bash
kubectl logs -n flare-system deployment/flare-operator --tail=200
```

Critical for:
- State transition events
- Topology broadcast confirmations
- Error messages

### 2. flared Pod Logs

```bash
kubectl logs -n flare-system <pod-name>
```

Useful for:
- Connection attempts
- Reconstruction progress
- Error conditions

### 3. E2E Test Output

```bash
.lake/build/bin/flare_e2e
```

Provided:
- Key distribution metrics
- Test assertions
- Step-by-step validation

### 4. C++ Source Code

Reading the original implementation was **essential** for understanding:
- Expected behavior
- Protocol semantics
- State machine design

### 5. Lean #eval Output

```lean
#eval reconcileStep ...
```

Helpful for:
- Verifying state transitions
- Testing pure functions
- Debugging logic errors

## Recommendations for Future Debugging

### 1. Add Structured Logging

**Current**: String-based logs
```lean
IO.eprintln s!"[TRACE] Event: NodeAdd {nodeKey}"
```

**Proposed**: JSON structured logs
```lean
logEvent {
    level := "TRACE",
    event := "NodeAdd",
    nodeKey := nodeKey,
    role := node.role,
    partition := node.partition
}
```

**Benefit**: Easier to parse and analyze with tools like `jq`

### 2. Add Distributed Tracing

**Proposed**: OpenTelemetry spans for:
- Reconcile loop iterations
- Topology broadcasts
- State transitions

**Benefit**: Visualize causality across distributed components

### 3. Add State Dumping

**Proposed**: HTTP endpoint to dump current `FlareClusterState`

```bash
curl http://operator:8080/debug/state
```

**Benefit**: Inspect state without parsing logs

### 4. Add Protocol Recording

**Proposed**: Option to record all protocol messages

```bash
flare_operator --record-protocol /tmp/protocol.log
```

**Benefit**: Replay and analyze protocol interactions

### 5. Property-Based Testing

**Proposed**: Use Lean's proof capabilities for property testing
```lean
theorem allKeysDistributed (state : FlareClusterState) :
    ∀ key, ∃ partition, key ∈ partition.keys := by
    sorry
```

**Benefit**: Catch bugs before they reach production

## Timeline

- **Day 1**: Noticed P0=100, P1=0 distribution
- **Day 2**: Discovered P1 Master stuck in Prepare state
- **Day 3**: Found zero NodeState events in logs
- **Day 4**: Analyzed C++ source code, discovered state transition requirements
- **Day 5**: Implemented topology broadcast architecture
- **Day 6**: Implemented Proxy→Master transition flow
- **Day 7**: Fixed P0 Master reconstruction bug
- **Day 8**: Discovered partition-size out-of-bounds bug
- **Day 9**: Final fix, all tests passing ✓

**Total**: 9 days of investigation and implementation

## Conclusion

This debugging journey demonstrates the importance of:
- **Deep source code analysis** over black-box testing
- **Understanding original architecture** when replacing components
- **Layered debugging** from symptoms to root causes
- **Verifying assumptions** against implementation details

The final solution required fixing **three interconnected bugs** that spanned communication architecture, state machine design, and memory safety. Only by understanding the complete system could we identify and fix all issues.
