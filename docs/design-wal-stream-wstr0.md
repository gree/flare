# WSTR-0: WAL streaming and WAL-only delivery — audit and protocol design

Status: **DRAFT for review. Audit and design only; nothing here is implemented.**
Plan: [PLAN-WAL-STREAM-ONLY.md](PLAN-WAL-STREAM-ONLY.md) (WSTR-0). Prepared
2026-10-05 on branch `safety/saf-10-wal-replication`, local HEAD `655dd49`
(code baseline `ac49d67`). No defaults, production flags, tags, pf-dev changes
or approvals come from this document. WSTR-n are planning labels; the UCA/EV
numbers in §8 are PROPOSED and not allocated in `safety-evidence.json` until
review.

Baseline at writing: PR #144 Draft. E2E run 37296281060 on ac49d67 was still
running (authority leg failed, wal-recovery leg in progress); nix-linux
37296281252 passed (C++ with and without RocksDB, aggregate cutter PASS,
individual test names not visible). Results are recorded in the evidence
ledger separately.

How the audit was done: three read-only passes over flared mutation paths,
the follower transport and the operator control plane, cross-checked by hand
for the findings marked **(verified)**. File references are to the working
tree at 655dd49; `S` = `src/lib/storage_rocksdb.cc`.

## 1. What the baseline actually does

**Delivery today is HYBRID.** Every client mutation on the master is a
default-column-family RocksDB write with the WAL on (`_write_options.disableWAL
= false`; no compaction filter, DeleteRange, ingestion or Merge anywhere). The
master then forwards the operation to every slave of the partition
(`cluster::post_proxy_write`, cluster.cc:1597; no per-recipient filter), tagged
`rl=<source_epoch>/<seq_label>` only when `repl-identity-forward` is on
(default off). A follower (`repl-follow-enabled`, default off) independently
POLLS the master's WAL. Both paths go through the common apply rule
(`_decide_change`, S:2578): the epoch must match, a label at or below the
applied cursor is skipped, and per-key metadata orders the rest. Late or
duplicate forwards are harmless no-ops.

**The follower is pure polling.** Each poll opens a NEW TCP connection
(handler_wal_follower.cc:216), sends `repl_sync_wal <cursor> <master_id>
<expected_epoch> <max_batches> <max_bytes>`, reads `EPOCH <epoch> <head>`, then
`LSN <seq>` / `BATCH <size> <crc32>` / bytes per batch, optional `MORE`, and
`END`. When it is caught up it sleeps `repl-follow-poll-interval-usec`
(default 200 ms). There is no wakeup hook on writes, no protocol version, no
heartbeat and no long-lived stream. The receiver incarnation is checked only
locally. Low latency comes from forwarding; the WAL path gives gap-free
recovery.

**Apply is crash-atomic.** `apply_wal_batch` (S:2931) decodes outside locks,
then under `_repl_apply_lock` (exclusive) and `_mutex_wholelock` (read)
commits data, metadata-CF rows and the cursor in one WriteBatch. No network I/O
happens under a lock. Only CF 0 entries are applied; reserved keys are numbered
but skipped; Merge/DeleteRange refuse the whole batch.

**Control plane.** Configuration is one cluster-wide `extra.conf`
(`toExtraConf`); there is no per-replica mode. The operator reads each
Ready slave's stats every pass in WAL mode (FollowEvidence `Reading`),
withholds reads (balance 0) unless the replica is `following`, same epoch,
observed within 5 s and within `readLag`, and ranks promotion candidates by
applied position. flared has its own local read guard
(`follow_allows_local_read`, stats.h:194, hardcoded 5 s) that keeps working
when the operator is down. Follow mode memory, the new confirmation list and
the hold clock are in memory only; the repair ledger is in CR status.

## 2. Mutation-path audit (summary)

| Path | Master WAL | Reaches replicas today | Replica mutates locally | WAL-only risk |
|---|---|---|---|---|
| set/add/replace/append/prepend/cas | yes (full resulting value) | forward + WAL | no | low |
| incr/decr | yes (resulting value via set) | forward (as set) + WAL | no | low |
| touch/gat | yes (full value) | forward WITHOUT identity tag + WAL | replica runs a plain set | low (forward goes away) |
| delete | yes | forward (tagged) + WAL | no | low |
| **lazy expiry on get** | yes on the master | WAL only | **yes — any node's get() physically deletes (verified, S:1087-1099; no role check)** | **HIGH** |
| reaper | yes (master-only gate, handler_reaper.cc:175) | untagged versioned delete forward + WAL | no | low |
| flush_all / truncate | per-key deletes, then `advance_source_epoch("bulk")` | WAL deletes, then the epoch change forces rebuild | yes if sent to a replica (no role guard) | medium |
| orphan_purge | yes if run on the master | not forwarded | **yes if run on a replica (no role guard)** | medium |
| tombstone sweep | replica's own meta CF | n/a | metadata only | low |
| WAL batch apply / forwarded apply | replica WAL | — | the stream itself / goes away | — |
| verbatim `apply_batch_with_lsn` | replica WAL | reconstruction, and the follower when the reply has no EPOCH | copies the source's reserved keys and other-CF records raw | medium |
| dump receive | replica WAL, no metadata | reconstruction | yes | medium (see D9) |
| snapshot swap / hard_reset / sentinel discard | not WAL (whole-DB replacement) | bootstrap / rebuild | yes, by design | low |
| reserved keys (master_id, epoch, incarnation, last_lsn, rebuilt_from) | yes, CF 0, skipped by the decoder | not replicated | yes, local identity | low |
| backup checkpoint | no logical change | — | prunes backup dirs only | none |

Conclusion: every authoritative data mutation reaches the master's WAL as a
normal write. With forwarding disabled, replicas would still receive every
change, EXCEPT that a replica may itself delete keys outside the stream (lazy
expiry, a replica-local orphan_purge or flush_all). Expired-read FILTERING is
fine; physical deletion on a replica is not.

## 3. Pre-existing defects found (fix on the shared paths, separately)

These affect today's hybrid follower, not only the future design. Each needs
its own change and test; none is fixed by this document.

| # | Defect | Where | Effect |
|---|---|---|---|
| D1 | A replica's `get()` physically deletes an entry it judges expired, by its own clock, writing no repl metadata | S:1087-1099 (verified) | Divergence: with clock skew, or a touch on the master not yet delivered, the replica drops a key the master still holds; nothing resends it until its next write. Proposed: filter on read, delete only on the partition master. |
| D2 | A follow reply with no `EPOCH` line is applied VERBATIM (`apply_batch_with_lsn`) | op_repl_sync_wal.cc:608-631 (verified) | Contradicts fail-closed: an older or misbehaving source bypasses the common apply rule and its reserved keys are copied raw. Proposed: in follow mode, no EPOCH = refusal (`no_epoch`, error state). |
| D3 | `lexical_cast` of the `LSN` and `BATCH` size tokens is not guarded | op_repl_sync_wal.cc:521, 540 (verified: no enclosing try) | A garbled frame throws an uncaught exception in the follower thread. |
| D4 | Mid-frame failures return -1 without setting `_client_result` | op_repl_sync_wal.cc after the LSN line | Classified as server error instead of disconnected (wrong state and backoff). |
| D5 | Serving-side limits (`batch_too_large`, bwlimit) are never configured for the follower's requests; one batch of any size can exceed `max_bytes` | op_parser_text_node.cc:133, S:2379-2417 | Unbounded reply size from a single large batch. |
| D6 | `get_updates_since` / `get_latest_sequence_number` take no lock | S:2372-2417 (verified) | Can race a DB handle swap (snapshot swap, hard_reset). |
| D7 | Follower stop is asynchronous and not awaited | cluster.cc:1717 | An old and a new follower may overlap; only the apply lock and contiguity check guard it. |
| D8 | `orphan_purge` and `flush_all` have no role guard | op_orphan_purge.cc, op_flush_all.cc | A replica mutates outside the stream (flush_all also changes its epoch). |
| D9 | A dump-rebuilt replica has its own bulk epoch, so it can never follow; only snapshot bootstrap adopts the source epoch | S:1393 vs S:1911-1939 | Today hidden by forwarding (and handled by needs_rebuild → snapshot). In WAL-only a dump-built replica receives nothing. WAL-only therefore requires snapshot initialisation (as the plan says). |
| D10 | Poll interval and follow limits are copied when the follower starts; reload does not reach a running follower | handler_wal_follower.cc:51, cluster.h:309 | Config changes need a follower restart to apply. |
| D11 | `repl_identity_forward` is not exported in stats | op_stats.cc | The operator cannot observe whether identity forwarding is on. |

Proposed order: D1, D2, D3, D4 and D8 first (small, safety-relevant, testable
in cutter), then D6/D7 with WSTR-1 (they touch the same code), D5/D10 with the
transport, D11 with WSTR-3.

## 4. Modes, capabilities and versioning

Two independent axes (names are conceptual until the schema is reviewed):

- **Delivery mode** (per replica): `legacy` (forwarding only), `hybrid`
  (forwarding + WAL, today's follow mode), `wal-only` (no write forwarding to
  this replica).
- **Transport** (per follower): `poll` (today's `repl_sync_wal` loop) or
  `stream` (§5).

Capabilities are advertised in `meta features`, which the follower must now
query before choosing a transport (it does not today):

- `wal_stream=1` — the source serves protocol version 1 of `repl_stream`.
- `wal_only=1` — the source can stop forwarding to a named recipient and
  reports it (§6). A source that does not advertise it is never asked to; a
  replica never assumes it.

Negotiation: the follower uses `stream` only if the source advertises
`wal_stream>=1` AND local config enables it; otherwise `poll`. Any
`SERVER_ERROR version_unsupported` or unknown reply to `repl_stream` falls
back to `poll` for a bounded period and is counted. An older peer never sees
a WAL-only request: the operator only requests WAL-only for a recipient whose
source advertised `wal_only=1` in the SAME process (boot id) it observed.

## 5. Stream protocol v1 (WSTR-1)

**Open.** `repl_stream 1 <partition> <master_id> <expected_epoch>
<receiver_incarnation> <cursor> <max_frame_bytes> <max_inflight_bytes>
<heartbeat_ms>` on a dedicated connection. The server refuses, in this order,
with the same vocabulary as `repl_sync_wal` plus new reasons:
`version_unsupported`, `not_master` (this node is not the partition's
master in its current map), `wrong_partition`, `master_id_mismatch`,
`lsn_ahead`, `generations_unavailable`, `epoch_mismatch`, `lsn_purged`. On
acceptance: `STREAM 1 <epoch> <head> <server_time_ms>`. The receiver
incarnation is echoed into every frame so a stream opened for one copy can
never be applied to a replacement copy.

**Frames.** One frame = one or more WHOLE batches, never a split batch:

```
F <first_seq> <last_seq> <nbatches> <payload_bytes> <crc32> <incarnation>
  B <seq> <count> <size> <crc32>   (raw bytes, size)   … nbatches times
E
H <epoch> <head> <server_time_ms>                       (heartbeat, no payload)
X <reason> [detail]                                     (terminal; then close)
```

`last_seq = seq + count − 1` of the last batch: the frame states the sequence
range it covers, so the client can check contiguity before applying
(`first_seq ≤ cursor + 1` else gap → `needs_rebuild(lsn_purged)`), and
duplicates (`last_seq ≤ cursor`) are skipped by the existing rule. Sequence
numbers count DB operations (including reserved-key and metadata writes), not
application keys. Metadata-only batches keep advancing the cursor as today.
Partial frame, bad CRC, bad count or a malformed token: nothing from that frame
is applied, the stream is closed as `protocol_error` (disconnected → resume
from the durable cursor). All numeric parsing is guarded (D3).

**Size rules.** Frames are at most `max_frame_bytes` EXCEPT a single batch
larger than that, which is sent alone; a single batch larger than the hard
ceiling (`repl-stream-max-batch-bytes`) ends the stream with
`X batch_too_large <n>` and the follower declares `needs_rebuild(oversized)`
— explicit, never retried forever, never split.

**Flow control.** The client sends `A <applied_cursor>` after each applied
frame (and with every heartbeat answer). The server keeps
`bytes_sent − bytes_up_to(acked cursor) ≤ max_inflight_bytes`; it never
buffers the backlog: it reads the WAL from the acked position in bounded
chunks. Resume after any disconnect is from the follower's DURABLE cursor,
never from bytes received.

**Waiting without losing a write.** Server tail loop:

1. read WAL from `next` up to the frame limit; send; repeat while data exists;
2. arm the wait: under the stream's mutex read `head = GetLatestSequenceNumber()`;
   if `head ≥ next`, go to 1 (re-check AFTER arming);
3. wait on a condition variable signalled after every successful write in
   `storage_rocksdb` (one write-generation counter + broadcast at the end of
   each write method, including internal writes: reaper, purge, reserved keys,
   apply), with a BOUNDED timeout (`repl-stream-idle-wakeup-ms`, proposed
   50 ms) — the WAL remains the truth if a signal is ever lost;
4. send `H <epoch> <head> <time>` at least every `heartbeat_ms`.

The latency guarantee is therefore "≤ the bounded wakeup in the worst case",
not "immediate"; it is measured (§9), not promised.

**Liveness, idle vs stalled.** The client's read deadline is
`3 × heartbeat_ms`; a missing heartbeat = disconnected. Freshness of the
source head comes ONLY from `H` frames and frame headers (sub-second server
time), and is distinct from applied progress. Idle: `applied ≥ head` with a
fresh heartbeat. Stalled: head ahead of applied and not moving for
`stall_ms`, or no fresh heartbeat. Neither an open socket nor an Active label
is freshness.

**Cancellation and resources.** One stream per (source, replica). The server
serves streams on a dedicated bounded pool (`repl-stream-max-streams`), never
on the request pool; excess opens get `X busy`. WAL reads take
`_mutex_wholelock` for read only while copying a bounded chunk (D6); no
application or apply lock is held while waiting on a socket. Every stream
thread is cancelled by `shutdown(fd)` + flag on: demotion, source change,
epoch change (promotion, flush_all, truncate), mode change, receiver reset
(hard_reset, snapshot swap) and process shutdown. The client's stop is
awaited with a deadline (D7). Reconnect uses bounded exponential backoff with
jitter (100 ms → 5 s) and works with no further client writes.

**Retention.** Unchanged: WAL is retained by TTL and size, independent of the
slowest replica. A cursor older than the retained WAL is
`needs_rebuild(lsn_purged)`. The acked cursor is reported in stats for
visibility only; it does not extend retention and is not a durability claim.
The stream holds no WAL iterator between chunks, so it pins no files.

## 6. WAL-only delivery (WSTR-2, preview — for review, not implemented)

- The master stops WRITE forwarding only to a recipient whose node-map entry
  carries the WAL-only flag AND whose stream it currently serves under the
  same epoch and incarnation; every other recipient keeps forwarding. Client
  write proxying to the master and replica→master READ proxying are
  unchanged. The master exports, per recipient, `forwarding=on|off` (D11).
- A replica enters WAL-only only after a sequence-bound snapshot plus stream
  catch-up (D9); a dump-built replica stays hybrid until a snapshot rebuild.
- Replica-local deletion outside the stream must be gone first (D1, D8): this
  is a hard prerequisite for WAL-only.
- Any epoch or incarnation change invalidates the stream and the replica's
  WAL-only readiness; it starts again from catch-up.
- Read eligibility stays as today (fresh source head, lag, same epoch), now fed
  by heartbeats; the flared local guard remains authoritative when the
  operator is stale. Transient lag → reads proxied to the master, never a
  demotion or rebuild. Master unreachable → explicit unavailable
  (`read-unavailable-error`), never a known-stale local value.

## 7. Cutover and rollback (WSTR-3, preview — for review, not implemented)

Per replica, persisted in CR status beside `replicaRepairs` (so it survives an
operator restart), each observation bound to the replica's pod UID, boot id,
epoch and incarnation:

```
Hybrid ──(capability seen: source wal_stream+wal_only, replica stream)──▶ CatchUp
CatchUp ──(stream following, same epoch, applied ≥ head − readLag, fresh)──▶ Boundary
Boundary: record B = master head; wait applied ≥ B (contiguous, durable)
Boundary ──(applied ≥ B)──▶ ForwardOffRequested  (node-map WAL-only flag for R)
ForwardOffRequested ──(master reports forwarding=off for R, same boot/epoch)──▶ WalOnly
any phase ──(epoch/incarnation/boot change, Unknown, timeout)──▶ back to Hybrid (forwarding on)
```

Writes crossing the boundary are safe because, until the master confirms
`forwarding=off`, they arrive by BOTH paths and the common rule keeps the
newer; after it, they arrive by the stream, which is already contiguous past
`B`. Unknown never advances a phase, promotes or deletes. One replica first,
with an independently healthy copy; never all copies of a partition.

Rollback: request forwarding ON for R → confirm `forwarding=on` on the master
→ only then stop the stream. Forwarding cannot repair an existing gap: if R is
behind, the stream stays until it is caught up, or R is rebuilt. A binary that
cannot read the persisted format is refused (migration/restore plan instead).
Configuration confirmation is tracked until success or a visible timeout,
including across operator restart (the current in-memory `Confirm` list is the
model; it needs persistence for this use).

A promotion during cutover: the new master starts with forwarding ON to every
recipient (default), so a WAL-only replica falls back to hybrid automatically;
the phase returns to `Hybrid`.

## 8. STPA delta (proposed; IDs not allocated)

Existing UCAs the work touches, re-checked rather than replaced: UCA-19
(fetch not resumed), UCA-20 (position past an unapplied range), UCA-23
(crash between apply and position), UCA-24 (old session/lineage applied),
UCA-25 (history gone treated as synced), UCA-26 (lagging replica eligible),
UCA-27 (WAL retained to exhaustion), UCA-29 (decision against a stale
position), UCA-30 (previous session after rebuild), UCA-31 (a change without an
order label — D1/D8 are instances), UCA-32 (disconnect → rebuild), UCA-33
(partially initialised copy). Controls EV-16..EV-20 are shared code and must
be re-assessed when the transport lands.

Proposed new UCAs (action A6 replica fetch unless noted):

| Proposed | Action | Type | Unsafe control action | Hazards |
|---|---|---|---|---|
| UCA-34 | A3/A6 | Too early | Forwarding to a replica is disabled before its stream is contiguous past a recorded boundary | H3, H2 |
| UCA-35 | A5 | Not provided | The source waits for new WAL and misses a write committed between "no more WAL" and "begin waiting" | H3 |
| UCA-36 | A6 | Provided | A stream from an old role, epoch, incarnation or mode survives the change and keeps applying or reporting freshness | H2, H3, H4 |
| UCA-37 | A5 | Provided | A slow or blocked replica's stream pins memory, workers or WAL and starves other replicas, client service or lease renewal | H1, H4 |
| UCA-38 | A6 | Provided | A replica deletes stored data outside the stream (lazy expiry, local purge/flush) | H3 |
| UCA-39 | A3 | Wrong order | Rollback disables the stream before forwarding is confirmed, losing the only gap-recovery path | H3 |
| UCA-40 | A1/A3 | Provided | A missing or unreadable observation is taken as mode confirmation or successful cleanup | H3, H4 |

Proposed new controls (to be mapped after review): stream contiguity and
re-check-after-arm (UCA-35, -20); stream identity binding and cancellation on
every identity change (UCA-36, -24); bounded stream resources on a dedicated
pool (UCA-37, -27); master-only physical deletion (UCA-38, -31); boundary +
confirmed forwarding-off cutover and confirmed forwarding-on rollback (UCA-34,
-39); persisted, identity-bound confirmations where Unknown never advances
(UCA-40).

## 9. Measurement contract and proposed thresholds

Production targets are NOT known: write rate, burst size, key/value
distribution, replica count, acceptable replication p95/p99, proxy p99,
acceptable lag and recovery time must come from the release owner. Until
then CI establishes RELATIVE behaviour only and cannot approve capacity.

Proposed CI measurement (same CPU/memory/storage settings for every arm):

- Arms: hybrid+poll (baseline, today), hybrid+stream, WAL-only+stream, and
  WAL-only+poll (isolates the transport).
- Metric 1 — commit-to-local-visibility on the replica: the master writes
  `k=v_n` with a timestamp; a probe on the replica reads LOCALLY (readBalance
  routed to the replica, `cmd_get` on the master unchanged, same UIDs/boot ids)
  until it sees `v_n`; record p50/p95/p99 over ≥ 2000 writes at idle-then-one,
  steady 200 w/s and a 2000-write burst.
- Metric 2 — client latency p99 of set and of proxied get, master and replica.
- Metric 3 — catch-up after a 60 s disconnect at steady load: time to
  `applied ≥ head`, no rebuild.
- Metric 4 — resources: master RSS/threads with one healthy and one blocked
  replica; WAL bytes retained.

Proposed thresholds for CI acceptance (relative, to be confirmed):

| Parameter | Proposed |
|---|---|
| heartbeat interval | 200 ms; client read deadline 3 × heartbeat |
| idle wakeup bound (`repl-stream-idle-wakeup-ms`) | 50 ms |
| frame / in-flight / hard batch ceiling | 1 MiB / 8 MiB / 64 MiB |
| max streams per source | replicas + 2 |
| reconnect backoff | 100 ms → 5 s, ±20 % jitter; connect timeout 3 s |
| hybrid+stream visibility p99 at 200 w/s | ≤ 100 ms and ≤ baseline hybrid+poll WAL-path p99 / 2 |
| WAL-only+stream visibility p99 at 200 w/s | ≤ 150 ms |
| client set / proxied get p99 | within +10 % of baseline |
| catch-up after 60 s disconnect at 200 w/s | ≤ 30 s, zero rebuilds |
| blocked replica | master RSS growth ≤ 64 MB; healthy replica p99 within +10 % |

## 10. Proposed next steps (each after review)

1. Reconcile documentation labels: mark CONTRIBUTING's reconstruction-only WAL
   text and the continuous-WAL design's "no implementation" header as
   historical, pointing at this baseline (docs only).
2. Fix D1-D4 and D8 on the shared paths with cutter tests, as their own change
   (separate from the transport).
3. Baseline benchmark harness for hybrid+poll (§9 metrics 1-4) as an opt-in
   CI job, with archived results.
4. WSTR-1 transport (§5) behind an opt-in, default-off option, poll retained,
   with D5-D7/D10.
5. WSTR-2/3 only after WSTR-1's CI evidence and a second review.

## 11. Questions for the reviewer

1. Is the stream framing (whole batches per frame, explicit seq coverage,
   client acks for flow control) acceptable, or is a simpler one-batch-per-frame
   design preferred at the cost of overhead?
2. Is a write-generation condition variable in `storage_rocksdb` (signalled
   by every write method) acceptable as the wakeup, with the bounded 50 ms
   fallback?
3. Should D1 (replica lazy-expiry deletion) be fixed now for hybrid as well?
   It is a divergence path today, independent of WAL-only.
4. Per-replica mode: node-map flag (operator-owned, per entry) vs. a
   per-pod config file. The draft prefers the node-map flag because the master
   must know per recipient.
5. Who provides production targets for §9, and may CI run the
   WAL-only+poll arm (it exists only to isolate the transport)?
