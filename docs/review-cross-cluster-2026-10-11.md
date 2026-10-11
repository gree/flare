# Cross-cluster forwarding: what is guaranteed, what is not (2026-10-11)

Scope: the EXISTING cluster-replication path (`cluster-replication*` flared
options, `spec.clusterReplication` in the FlareCluster CR) used for the
initial ingest and the follow before a web cutover. No new design (WAL
streaming etc.) is proposed here. Read-only audit of the current code plus
two fixes for detection gaps; **no repair is implemented**.

**Verdict for 10/12:** cluster replication can copy what exists when it
starts (the seed). It does NOT guarantee delivery of writes acknowledged
after that. A dropped forward is counted (after the fixes below, on every
path found) but never repaired. **Real-data ingest that relies on the
follow is NOT ready on this basis.** An ingest whose correctness is checked
by a verification step before the cutover (R3 below), with writes quiesced,
is the only form the existing mechanisms support.

## 1. One acknowledged write

| step | where | note |
|---|---|---|
| local write, then `post_proxy_write`, then the client reply | src/lib/op_set.cc:192, :210 | the reply does not wait for the forward |
| `cluster_replication::on_post_proxy_write` (master only) builds `queue_proxy_write(NULL, NULL, …)`, `post_proxy=true`, enqueues async | src/lib/cluster_replication.cc:227-238 | `_cluster == NULL`: no source epoch / sequence tag is carried (queue_proxy_write.cc:149-155) |
| owner: one of `concurrency` threads, by key hash | cluster_replication.cc `_enqueue` | one TCP connection per thread; queue unbounded |
| send: up to 4 tries, reopening the connection | queue_proxy_write.cc:157-171 | DNS lookup on every open; read timeout 10 min (connection_tcp.cc:37) |

## 2. Where a forward is lost, and whether it is seen

| path | before | after c2971d4 |
|---|---|---|
| 4 tries exhausted | counted `proxy_write_dropped[dest]` + log (key) | same |
| fail-fast (last open timed out < window) | counted, log 1/100 | same |
| thread shut down with items queued | counted ("ABANDONED") | same |
| **first connect at start fails** (name not in DNS yet, destination down at enable / pod start) | thread RETURNED, left the pool; replication stayed `started`; a SIGHUP with the same name/port does not restart it (`start()` → "already started") | thread stays; each forward reconnects; failures counted |
| **no active forwarding thread / enqueue refused** | `log_notice`, NOT counted | counted under the destination, log 1/100 |
| destination answers but does not store (SERVER_ERROR behind an LB, older version) | warning 1/100, NOT counted | **unchanged — still not counted** |
| seed thread's first connect fails | returns (handler_dump_replication.cc:79-83) — no seed | **unchanged** |

Nothing records WHICH writes were dropped beyond rate-limited log lines;
there is no cursor to resume from.

## 3. Failure cases

- **Connection break:** the in-flight forward is retried on a new
  connection (a forward applied whose reply was lost is sent again —
  idempotent set/delete/touch). Every forward failing 4 tries is counted
  and lost. A half-open socket can hold a thread up to 10 min.
- **Destination restart:** forwards during the outage are counted and lost;
  a destination that comes back EMPTY (tmpfs) is not noticed and nothing
  re-seeds it.
- **DNS failure:** mid-run, counted per forward, recovers by itself; at
  start, see §2 (fixed for the forwarding thread, not for the seed).
- **Destination behind a Service / LB:** a thread sticks to one backend;
  drops are attributed to `svc:port`; a non-storing answer is uncounted.

## 4. Who owns repair today

Nobody. The source operator reads `proxy_write_dropped[...]`, cannot map a
destination outside its cluster to a node, logs `CRITICAL: writes were
dropped to destination(s) outside this cluster` (Main.lean, RUNBOOK) and
keeps the entry; the destination operator never reads it. The only repair
the mechanisms allow is a full re-seed:

- snapshot-push refuses a destination with more than 4096 items
  (op_repl_snapshot_push.cc:197), so a populated destination falls back to
  the merge dump;
- the merge dump never deletes on the destination (a dropped delete stays
  wrong) and a stale-version set is NOT_STORED;
- the seed runs only from `start()`: flared boot as master, a name/port
  change, or `enabled` false → true.

## 5. Options within the existing mechanisms (decision needed)

| | what | cost / risk | status |
|---|---|---|---|
| R2 | count every silent drop path | small flared change | **done for 2 paths (c2971d4); non-storing answer and seed early exit open** |
| R1 | any foreign drop (or a destination restart) → hold the cutover → wipe the destination partition → toggle `enabled` false→true (snapshot-push re-seed) | destination wipe is destructive; needs a decision on who triggers it | procedure only, NOT exercised |
| R3 | before the cutover, with writes quiesced: per-partition key count + digest, source vs destination | needs a digest command or a key scan; time grows with data | not implemented |

## 6. Counterexample tests

| fault | test | state |
|---|---|---|
| destination name unresolvable at enable | `cluster-replication-faults` (32dffd4): every acknowledged write is on the destination or counted; writes after the name resolves arrive | old code 32dffd4, 38099336800: FAILED — 10 + 20 acknowledged, 0 arrived, drop counter 0 → 0 (silent loss of every write); fix c2971d4, 38099346715: passed — the 10 written while unresolvable counted (0 → 10), the 20 after it resolved all arrived; cluster-replication 1-11 and snapshot-push-seed 13-18 still pass |
| normal connection break | write tagged keys during Forwarding, cut the connection (NetworkPolicy / kill), require arrived-or-counted per key | NOT written |
| destination restart (empty on return) | write during the restart, require arrived-or-counted, and detection of the empty return | NOT written; the empty-return detection does not exist |
| repair (R1) | after R1, all tagged keys on destination master AND slave, a key deleted during the fault absent | NOT written (no repair) |

Each must record its baseline (N > 0 keys absent before the repair) and
must not SKIP on 0 arrivals — the existing `cluster-replication` test
SKIPs when no key arrives (ClusterReplication.lean:192).

## UNKNOWN

- whether a blocking connect to a black-holed LB address reaches the
  fail-fast path (kernel ETIMEDOUT) or holds a thread;
- what a delete of a missing key returns behind an LB;
- whether the operator's enable → Dumping path waits for anything on the
  destination.
