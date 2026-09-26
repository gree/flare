# Memory configuration and selective read-guard follow-up

Baseline: 41db502 plus accompanying changes; runtime results pending CI.

The CRD accepts optional `spec.rocksdb.blockCacheSizeMb` (positive MiB),
`writeBufferSizeMb` (positive MiB), and `maxWriteBufferNumber` (at least 2).
The operator parses and renders them and migration provisioning preserves
them. The Helm pre-install ConfigMap seeds these startup-only settings before
the first pod starts; upgrades retain the existing operator-owned ConfigMap.
Unset fields retain flared defaults. Existing pods are NOT automatically
restarted: SIGHUP only warns that a DB reopen is required. Wait for mounted
file propagation before a planned, data-safe restart or migration. In
particular, deleting a tmpfs-backed pod is not a safe configuration operation.
For non-Helm provisioning, seed extra.conf before starting the data pods.

Example (sizing example, not a recommendation or an RSS guarantee):

```yaml
cluster:
  rocksdb:
    blockCacheSizeMb: 64
    writeBufferSizeMb: 16
    maxWriteBufferNumber: 3
```

Account for all column families' buffers, compaction, replication, allocator
overhead and any tmpfs data. Neither a simple cache-plus-buffer formula nor
these limits establishes a safe Pod memory limit. Automatic limit validation,
measured RSS, and runtime proof of the effective startup options remain open.
Reset fields explicitly to desired values: removing the final tuning field
does not currently clear the operator's existing extra.conf.

Validation added: six Lean checks (defaults, rendering, each memory-only
spec, migration preservation); Helm initial-config/CR rendering tests in CI;
wal-retention-config E2E checks CR readback (detecting schema pruning) and
ConfigMap output alongside existing WAL retention. These are configuration
delivery tests, not proof of changed live DB budgets.

Local: flare_unit 145/145 and E2E build pass. Helm lint passes. The initial
Helm test accidentally matched the CRD's nested kind rather than the CR;
fixed to require a whole unindented kind line. No full local cutter/kind run.

Previous E2E run 36246272773 at 41db502: read-guard cleanup now passed, but
the scenario failed its positive-local-balance precondition. The node-sync
payload rule alone did not reliably isolate topology. Revised test blocks
both directions between operator pod IPs and the replica, covering index
request replies as well as pushed maps. All rules are removed in finally.
This is a harness fix and is NOT a passing read-guard acceptance result.
