# Replica-visibility benchmark (WSTR-0)

`visibility_bench.py` measures **end-to-end visibility**: one process, one
monotonic clock, from SENDING a uniquely marked write to the master/primary
until the marker is first observed in the replica's data. It is not
commit-to-apply. Load is open-loop; timeouts are counted, never zero; a growing
backlog marks the rate as failed. `--self-test` checks the timing logic
against in-process fake servers. `report.py` tabulates absolute values and
differences from the `redis-aof` arm; it applies **no tolerance**.

The CI run (E2E suite `visibility-bench`, workflow evaluation `visibility`)
uses one kind node; its numbers are relative only and approve no production
latency target.

## The arms are NOT equivalent durability profiles

`redis-aof` is the closest Redis configuration to flare's default RocksDB
write path, chosen so neither side waits for fsync per write. It is **not**
an equivalent persistence guarantee. Differences recorded for review:

| | flare (as deployed in this benchmark) | Redis `redis-aof` | Redis `redis-mem` |
|---|---|---|---|
| Version | branch build (`flare-node-rocksdb:test`) | `redis:7.2.5` | `redis:7.2.5` |
| Storage engine | RocksDB, data + WAL on the PVC (`usePvc`, kind local-path) | in-memory dataset + AOF on the PVC | in-memory only |
| Per-write log | RocksDB WAL record per write (`sync_writes=false`: written to the OS, no fsync per write) | AOF append, `appendfsync no` (written to the OS, fsync left to the kernel) | none (`appendonly no`, `save ""`) |
| Recovery after a process crash | replays the RocksDB WAL from the OS page cache | replays the AOF from the OS page cache | data lost |
| Recovery after a node/kernel crash | writes not yet flushed by the OS are lost | same | data lost |
| Replication | async: master forwards each write (legacy), plus WAL polling (hybrid, follow on) | async primary → replica stream | same as AOF arm |
| Replica read | local only if the master's `cmd_get` did not move during the run (else INVALID) | local (read-only replica) | local |
| CPU / memory limit | 500m / 512Mi (flared) | 500m / 512Mi | 500m / 512Mi |
| Not matched | flare's production pf-dev uses **tmpfs** for data (no disk at all); the benchmark uses a PVC on both sides. RocksDB compaction, the WAL archive (TTL/size retention) and memtable flushes have no Redis counterpart; Redis rewrites the AOF in the background (BGREWRITEAOF), flare does not. |

A `redis-mem` result is an additional latency reference only. Neither side
waits for a replica acknowledgement (no WAIT); replication is asynchronous on
both.
