# TODO & Future Improvements

## Current Status

✅ **Core Functionality Complete** (as of commit `a9ef225`)
- Even key distribution (P0≈50%, P1≈50%)
- Automatic failover working
- State machine integration complete
- All E2E tests passing

## Known Issues

### 1. Test Assertion Mismatch

**Issue**: E2E test expects `partition-size 2` but operator correctly returns `partition-size 1024`

**Status**: Test assertion is wrong, not the code

**Fix Needed**:
```lean
-- In FlareOperator/E2E/Tests/*.lean
-- Change:
assertEq ("partition-size", "2") -- ❌ Wrong
-- To:
assertEq ("partition-size", "1024") -- ✅ Correct
```

**Priority**: Low (cosmetic test fix)

### 2. Invariants Proofs Broken

**Issue**: `FlareOperator/StateMachine/Invariants.lean` proofs don't compile after topology broadcast changes

**Status**: Operator builds without invariants using `lake build FlareOperator.Main`

**Impact**: Runtime behavior correct, but formal verification incomplete

**Fix Needed**: Update proof statements to account for:
- New `assignProxies` logic
- Hybrid P0/P1 assignment model
- Topology broadcast side effects

**Priority**: Medium (nice-to-have for formal verification)

### 3. Empty Pod IP in Broadcast

**Issue**: Occasional `[TcpClient] Invalid IP address: ` warnings in logs

**Root Cause**: K8s pod list sometimes includes pods without assigned IPs (ContainerCreating state)

**Current Behavior**: Warning logged, broadcast continues to other pods

**Fix Needed**: Filter pods by readiness before broadcast:
```lean
let pods ← listFlaredPods crName ns
let readyPods := pods.filter (·.ready)
broadcastTopologyToAllPods crName ns version nodes readyPods
```

**Priority**: Low (already handled gracefully)

## Planned Improvements

### Performance Optimizations

#### 1. Replace List with RBMap for Node Lookups

**Current**: O(n) linear search in `List (String × FlareNode)`

**Proposed**: O(log n) lookup using `Std.Data.RBMap`

```lean
structure FlareClusterState where
  nodeMap : RBMap String FlareNode compare  -- O(log n) lookup
  partitionMap : List FlarePartition
  -- ...
```

**Benefit**: Faster reconcile loops for large clusters (100+ nodes)

**Priority**: Medium

#### 2. Parallel Topology Broadcasts

**Current**: Sequential connections to each pod

**Proposed**: Parallel broadcasts using `IO.asTask`

```lean
let tasks ← pods.mapM fun pod => do
  IO.asTask (prio := .default) do
    sendNodeSyncToNode pod.ip 12121 version nodes

for task in tasks do
  match ← IO.wait task.result! with
  | .ok () => pure ()
  | .error e => IO.eprintln s!"Broadcast failed: {e}"
```

**Benefit**: Faster topology updates for large clusters

**Priority**: Medium

#### 3. Incremental State Updates

**Current**: Full node list broadcast on every change

**Proposed**: Send only changed nodes (delta updates)

**Challenge**: Requires protocol extension or version tracking

**Priority**: Low (premature optimization for current scale)

### Feature Additions

#### 1. Prometheus Metrics

**Proposed Metrics**:
```
flare_operator_reconcile_duration_seconds{cluster="my-cluster"}
flare_operator_node_map_version{cluster="my-cluster"}
flare_operator_dead_nodes_detected_total{cluster="my-cluster"}
flare_operator_topology_broadcasts_total{cluster="my-cluster"}
flare_operator_nodes_total{cluster="my-cluster",role="master",state="active"}
```

**Implementation**: Add HTTP server on port 9090, export metrics

**Priority**: High (observability critical for production)

#### 2. Graceful Scale-Down

**Current**: Deleting pods immediately removes nodes

**Proposed**: Drain keys before removal
1. Mark node as "draining" in ConfigMap
2. Wait for keys to migrate to replicas
3. Remove node from topology
4. Delete pod

**Priority**: Medium (nice-to-have for zero-downtime operations)

#### 3. Automatic Rebalancing

**Current**: Keys stay on original partition after scale-out

**Proposed**: Trigger rehashing to redistribute keys evenly

**Challenge**: Requires coordination with flared reconstruction

**Priority**: Low (can be done manually)

#### 4. Multi-Cluster Federation

**Proposed**: Manage multiple independent Flare clusters from one operator

**Implementation**: Watch all FlareCluster CRDs in namespace, run separate reconcile loops

**Priority**: Low (out of scope for initial release)

### Code Quality

#### 1. Add Integration Tests

**Current**: E2E tests only (full cluster deployment)

**Proposed**: Unit tests for pure functions
- `autoAssign` logic
- `detectDeadNodes` edge cases
- Protocol parsing/serialization
- State transition validation

**Priority**: Medium

#### 2. Refactor Main.lean

**Current**: 500+ lines, multiple responsibilities

**Proposed**: Split into modules:
- `Reconciliation.lean`: Core reconcile logic
- `LeaderElection.lean`: Lease management
- `ServiceRouting.lean`: K8s Service patching

**Priority**: Low (works fine, but harder to maintain)

#### 3. Add API Documentation

**Proposed**: Generate API docs from Lean docstrings

**Tool**: Use `lake` or custom script to extract comments

**Priority**: Low

### Reliability

#### 1. Retry Logic for K8s API Calls

**Current**: Single kubectl call, fails on transient errors

**Proposed**: Exponential backoff retry for:
- CRD fetch
- Pod list
- ConfigMap update

**Implementation**: Wrap `kubectl` calls in retry loop

**Priority**: High (production stability)

#### 2. Health Checks

**Proposed**: HTTP endpoints for liveness/readiness
- `/healthz`: Operator is running
- `/readyz`: Leader elected, TCP server listening

**Implementation**: Add HTTP server on port 8080

**Priority**: High (K8s best practice)

#### 3. Graceful Shutdown

**Current**: Operator exits immediately on SIGTERM

**Proposed**: On SIGTERM:
1. Release leader lease
2. Stop accepting new TCP connections
3. Finish in-flight reconcile loop
4. Close TCP server
5. Exit cleanly

**Priority**: Medium (improves restart stability)

## Research & Exploration

### 1. Custom Resource Status

**Proposed**: Update FlareCluster CRD status with:
```yaml
status:
  phase: Running
  nodeCount: 4
  masterCount: 2
  slaveCount: 2
  nodeMapVersion: 42
  conditions:
    - type: Ready
      status: "True"
      lastTransitionTime: "2026-03-13T00:00:00Z"
```

**Benefit**: Better K8s integration, visible in `kubectl get flarecluster`

**Priority**: Medium

### 2. Operator SDK Migration

**Current**: Custom kubectl wrapper

**Proposed**: Use Kubernetes client library (if Lean bindings available)

**Challenge**: No official Lean K8s client exists

**Priority**: Low (research project)

### 3. WebAssembly Deployment

**Proposed**: Compile Lean operator to WASM, run in lightweight runtime

**Benefit**: Smaller container image, faster startup

**Challenge**: Lean WASM support experimental

**Priority**: Low (research project)

## Documentation

### 1. User Guide

**Proposed Sections**:
- Installation
- Basic usage (deploy cluster)
- Monitoring
- Troubleshooting
- Upgrade procedures

**Priority**: High (required for production use)

### 2. Developer Guide

**Proposed Sections**:
- Setting up development environment
- Running tests
- Code structure overview
- Contributing guidelines

**Priority**: Medium

### 3. Migration Guide

**Proposed**: Guide for migrating from C++ flarei to Lean operator

**Sections**:
- Feature parity comparison
- Configuration differences
- Migration steps
- Rollback procedures

**Priority**: Medium (when promoting to users)

## Timeline Estimates

**Note**: These are rough estimates, not commitments

### Short Term (1-2 weeks)
- Fix test assertions ✅ (1 hour)
- Add retry logic for K8s API calls (2 days)
- Implement health checks (1 day)
- Prometheus metrics (3 days)

### Medium Term (1-2 months)
- Performance optimizations (RBMap, parallel broadcasts) (1 week)
- Integration tests (1 week)
- User guide documentation (3 days)
- Fix invariants proofs (1 week)

### Long Term (3-6 months)
- Graceful scale-down (2 weeks)
- Custom resource status (1 week)
- Automatic rebalancing (2 weeks)
- Multi-cluster federation (1 month)

## Non-Goals

**Explicitly NOT planned**:
- GUI/dashboard (use existing K8s tools like k9s, Lens)
- Alternative backends (only Flare supported)
- Multi-cloud support (K8s abstraction is sufficient)
- Custom scheduling (use K8s scheduler)

## Contributions Welcome

Areas where community contributions would be valuable:
- Performance benchmarking at scale (100+ nodes)
- Alternative deployment strategies (Helm charts, Kustomize)
- Integration with existing monitoring stacks (Grafana dashboards)
- Migration tooling from C++ flarei
- Language bindings for other platforms (Go, Rust clients)
