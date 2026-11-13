# Circuit Breaker Analysis - Simulation Results

## Executive Summary

The circuit breaker with 50% threshold provides **appropriate protection across all tested configurations**:
- ✅ **2-AZ deployments**: Trips on AZ loss (correct - infrastructure failure)
- ✅ **3-AZ deployments**: Survives 1-AZ loss (correct - sufficient capacity)
- ✅ **Single partition clusters**: Protected against split-brain
- ✅ **Disabled mode**: Works correctly for dev/test environments

## Simulation Results by Configuration

### Single Partition Clusters (1P)

| Config | Total Nodes | AZ Failure | Dead % | Breaker | Analysis |
|--------|-------------|------------|--------|---------|----------|
| 1P-1R-2AZ | 1 | AZ0 | 100% | **TRIP** | Only Master lost - correct |
| 1P-2R-2AZ | 2 | AZ0 | 50% | **TRIP** | Lost quorum - correct |
| 1P-3R-2AZ | 3 | AZ0 | 66% | **TRIP** | Lost majority - correct |
| 1P-3R-3AZ | 3 | AZ0 | 33% | **SAFE** | 2/3 remain - automatic failover OK |

**Recommendation**: Single partition clusters are inherently fragile. Circuit breaker provides critical protection against split-brain during network partitions.

### Multi-Partition with 2 AZ

| Config | Total Nodes | AZ Failure | Dead % | Breaker | Analysis |
|--------|-------------|------------|--------|---------|----------|
| 2P-1R-2AZ | 2 | AZ0 | 50% | **TRIP** | Infrastructure failure |
| 2P-2R-2AZ | 4 | AZ0 | 50% | **TRIP** | Infrastructure failure |
| 2P-3R-2AZ | 6 | AZ0 | 50% | **TRIP** | Infrastructure failure |
| 3P-1R-2AZ | 3 | AZ0 | 66% | **TRIP** | Infrastructure failure |
| 3P-2R-2AZ | 6 | AZ0 | 50% | **TRIP** | Infrastructure failure |
| 3P-3R-2AZ | 9 | AZ0 | 55% | **TRIP** | Infrastructure failure |

**Analysis**: Losing 1-of-2 AZs means **50%+ of infrastructure is gone**. Circuit breaker correctly identifies this as infrastructure failure and prevents:
- Cascading failure in surviving AZ from resource exhaustion
- Split-brain from K8s API hallucinations
- Unnecessary full syncs when AZ will likely recover quickly

### Multi-Partition with 3 AZ

| Config | Total Nodes | AZ Failure | Dead % | Breaker | Analysis |
|--------|-------------|------------|--------|---------|----------|
| 2P-3R-3AZ | 6 | AZ0 | 33% | **SAFE** | 4/6 nodes remain - automatic recovery safe |
| 3P-3R-3AZ | 9 | AZ0 | 33% | **SAFE** | 6/9 nodes remain - automatic recovery safe |

**Analysis**: With 3 AZs, losing 1 AZ means only 33% loss. Cluster has sufficient capacity to handle automatic recovery without risk of cascading failure.

### Circuit Breaker Disabled

| Config | Total Nodes | AZ Failure | Dead % | Breaker | Analysis |
|--------|-------------|------------|--------|---------|----------|
| 1P-2R-2AZ | 2 | AZ0 | 50% | **Disabled** | Always allows automatic recovery |
| 2P-3R-2AZ | 6 | AZ0 | 50% | **Disabled** | Always allows automatic recovery |

**Use Cases for Disabled Mode**:
- Development/test environments
- Single-node local testing
- Clusters with external load balancers handling failover
- Testing circuit breaker itself

## Key Insights

### 1. The Single Partition Problem

Single partition clusters (1P) are **inherently fragile**:
- All nodes serve the same partition
- Losing majority means losing the entire cluster's quorum
- Circuit breaker provides critical protection

**Example**: 1P-2R-2AZ (1 Master + 1 Slave across 2 AZs)
- AZ0 fails → lose 1 of 2 nodes (50%)
- Without circuit breaker: Operator creates new Master in AZ1
- If AZ0 recovers: **Split-brain** (2 Masters exist)
- With circuit breaker: Waits for manual intervention, prevents split-brain

### 2. 2-AZ Deployments Always Trip

This is **correct behavior**:
- 2-AZ deployment means no redundancy at AZ level
- Losing 1 AZ = losing 50%+ of infrastructure
- Circuit breaker identifies this as infrastructure failure
- Prevents resource exhaustion in surviving AZ

**Why this matters**: If AZ-A fails and Operator tries to rebuild all lost nodes in AZ-B:
- AZ-B must handle 2x traffic
- AZ-B must handle full synchronizations for all rebuilt nodes
- AZ-B network/CPU saturates → cascading failure
- Better to: Keep surviving nodes running, wait for AZ-A recovery

### 3. 3-AZ Deployments Work Optimally

With 3 AZs:
- Losing 1 AZ = 33% loss
- Remaining 2 AZs have 66% capacity
- Sufficient headroom for automatic recovery
- Circuit breaker stays **Closed** (allows automatic failover)

This is the **ideal production configuration**.

### 4. Hysteresis Prevents Flapping

Default configuration:
- **Trip threshold**: 50% dead
- **Reset threshold**: 80% healthy (20% dead)

This gap prevents **flapping** during borderline conditions:
```
Scenario: Nodes flickering during network issues
- 50% dead → Breaker trips → Manual intervention
- Network recovers → 20% dead (80% healthy) → Breaker auto-resets
- Operator resumes automatic recovery

Without hysteresis (trip = reset):
- 50% dead → Trip
- 49% dead → Reset
- 50% dead → Trip again (flapping!)
```

## Configuration Recommendations

### Production (2-AZ)
```yaml
circuitBreaker:
  enabled: true
  tripThresholdPercent: 50
  resetThresholdPercent: 80
  autoResetEnabled: true
```
**Rationale**: Protection against AZ failures, auto-recovery when infrastructure stabilizes.

### Production (3-AZ)
```yaml
circuitBreaker:
  enabled: true
  tripThresholdPercent: 50
  resetThresholdPercent: 80
  autoResetEnabled: true
```
**Rationale**: Same config works perfectly - won't trip on single AZ loss (33% < 50%).

### Development/Test
```yaml
circuitBreaker:
  enabled: false
```
**Rationale**: No production constraints, allow all automatic recovery for faster iteration.

### High-Availability (Conservative)
```yaml
circuitBreaker:
  enabled: true
  tripThresholdPercent: 30
  resetThresholdPercent: 70
  autoResetEnabled: true
```
**Rationale**: More sensitive to failures, trips earlier for extra safety.

### Manual-Reset-Only (Maximum Control)
```yaml
circuitBreaker:
  enabled: true
  tripThresholdPercent: 50
  resetThresholdPercent: 80
  autoResetEnabled: false
```
**Rationale**: SRE must manually restart operator pod after verifying infrastructure recovery.

## Validation

Hysteresis validation (trip < reset):
```
tripThresholdPercent=50 means trip when ≥50% dead
resetThresholdPercent=80 means reset when ≥80% healthy (≤20% dead)

Valid: 50% (trip) < 80% (100% - 20% dead) ✓
```

Invalid configuration example:
```
tripThresholdPercent=50
resetThresholdPercent=40  # Invalid! 100% - 40% = 60%, but 50% < 60% would cause flapping
```

Required constraint:
```
resetThresholdPercent > (100 - tripThresholdPercent)
```

## Conclusion

The circuit breaker design is **production-ready** and handles all tested scenarios correctly:

✅ **Single partition clusters**: Protected against split-brain
✅ **2-AZ deployments**: Correctly identifies AZ loss as infrastructure failure
✅ **3-AZ deployments**: Allows automatic recovery for single AZ loss
✅ **On/off flag**: Supports dev/test environments
✅ **Configurable thresholds**: Supports different operational requirements
✅ **Hysteresis**: Prevents flapping during borderline conditions

The 50%/80% default thresholds provide appropriate balance between protection and availability across all deployment scenarios.
