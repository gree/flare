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
| send: up to 4 tries, reopening the connection | queue_proxy_write.cc:157-171 | DNS lookup on every open; read timeout = connection_tcp::read_timeout copied at connect: **30 s in the k8s build** unless net-read-timeout is set (flared.cc:216 at startup, :536 on reload, both before cluster_replication::start at :434 / :622). Correction: this row said 10 min (the non-k8s default). Connect: blocking, 8 retries × ~130 s against a black hole (not bounded) — bounded in 4024a6c |

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
  and lost. A half-open socket holds a thread up to the read timeout (30 s
  in the k8s build; corrected from 10 min).
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

## 7. Second round (2026-10-11, commits 50f65f1 tests / 4024a6c fix)

### 7.1 What a destination's answer means, per op (4024a6c)

Before: any parsed answer ended the forward; a non-success answer was a
rate-limited warning, never counted. Now (`queue_proxy_write::_run_foreign`,
`classify_foreign_answer`; cross-cluster forwards only — in-cluster
forwards are unchanged):

| sent (post-proxy op) | answer | class | counted in proxy_write_dropped | why |
|---|---|---|---|---|
| set (set/add/replace/cas/append/prepend/incr/decr all go as a versioned set) | STORED | applied | no | |
| set | NOT_STORED | noop | no | the destination holds this version or a newer one (storage_rocksdb.cc:1823-1828): a retry whose first reply was lost, or a reordering |
| any | SERVER_ERROR | resent within the 120 s window (5345666), then failed | **yes, if it persists for the window** (`forward_server_error_retried` per resend) | the destination's transient refusal: a restarted node without its role answers it — 50f65f1 restart test: 21 changes answered SERVER_ERROR, none stored, none counted (log: `ANSWERED but not stored … op=delete, key=rst_pre_1, result=SERVER_ERROR`, 1 in 100) |
| set | CLIENT_ERROR / ERROR / EXISTS / NOT_FOUND / none | failed | **yes** (+ `cluster_replication[forward_failed_set_<result>]`) | not stored |
| delete | DELETED | applied | no | |
| delete | NOT_FOUND | noop | no | absent already, or the destination holds a newer version (storage_rocksdb.cc:2055-2069) — NOT unconditionally a loss |
| delete | anything else | failed | **yes** | the key may still be there |
| touch / gat | TOUCHED | applied | no | |
| touch / gat | NOT_FOUND | missing | no (`forward_missing_touch_not_found`, warning 1/100) | the destination lacks a key the source holds alive: an earlier drop (already counted), an expiry, or a newer delete there — a divergence signal, not a loss of this op |
| touch / gat | anything else | failed | **yes** | |

A client's `noreply` is no longer passed on to the destination (the answer
— and a broken connection — could not be seen with it).

Known limit: NOT_STORED cannot tell "same version" (benign) from "a
newer, different value written on the destination" (a divergence the
destination's clients caused). Duplicate mode assumes nobody writes the
destination before the cutover; the per-key verification (7.5) is what
catches it.

### 7.2 No answer: ride out, then count (4024a6c)

| | before | after |
|---|---|---|
| retries | 4 tries back to back (a refused destination: ~4.5 s per open × 4) | reconnect + resend with backoff 1, 2, 4 … 10 s for up to 120 s (`foreign_retry_window_ms`) |
| order | per thread (key hash) | same — later forwards wait behind |
| destination still down after 120 s | — | that forward counted (`dropped_retries`); the connection is marked given up: each later forward makes ONE attempt and is counted at once (`dropped_down`) until one is delivered — a dead destination does not hold every write for 120 s |
| connect | blocking, 8 retries (~130 s each against a black hole) | 3 s, 1 retry (as the in-cluster proxy) |
| stop / reload while waiting | — | the wait ends; counted (`dropped_stopping`) |

Accounting (stats `cluster_replication[...]`): `forward_enqueued` =
applied + noop_* + missing_* + failed_* + dropped_retries + dropped_down +
dropped_stopping + dropped_abandoned + in flight; `dropped_unqueued` were
never enqueued. With writes stopped and the queue drained, the identity
must close — the drain check in 7.5.

### 7.3 Seed (handler_dump_replication, 4024a6c)

| item | before | after |
|---|---|---|
| first connect fails | one log line, thread returns, replication stays "started", no seed | retried 6 times (5 s doubling to 60 s, ~2.5 min) — only while nothing was sent; then `cluster_replication_seed failed_connect` + CRITICAL log |
| observable state | none | `STAT cluster_replication_seed` connecting / transferring / completed_snapshot_push / completed_dump / failed_connect / failed_transfer / failed_busy / interrupted; counters seed_started / seed_connect_attempts / seed_completed / seed_failed |
| failure after sending started | "dump replication FAILED" log; resync failure counted on the SOURCE's own storage | state failed_transfer; NOT retried (a destination already partly written answers NOT_STORED to what it holds, which the dump counts as failed — see 7.4) |
| "Phase 1" WAL exchange | asked the DESTINATION for its WAL since the source's repl_last_lsn and applied it to the SOURCE's storage, then returned without seeding on success; guarded only by master_id, which a snapshot-push seed copies to the destination | removed — a seed never applies anything locally. Counterexample: E2E cluster-replication-reseed (result in 7.6) |

Unchanged and not fixed: the source's `rocksdb_resync_failure_count`
(alert FlareResyncFailing) still counts a failed cross-cluster dump as a
resync failure of the source itself.

**enable → Dumping (operator), audited:** the FlareCluster
`spec.clusterReplication` path sets the phase to Dumping as soon as it has
written `cluster-replication-mode = duplicate` and sent SIGHUP
(Main.lean handleClusterReplication); it reads nothing of the seed —
Dumping means "duplicate mode applied", never "seed done". The
FlareMigration path moves Duplicating → Forwarding when the target's
summed `curr_items` ≥ the source's for `convergenceDwellTicks`
(Migration/Controller.lean gatherObs): a key COUNT — equal counts with
wrong values, missing deletes, extra keys or different expiries pass it.
Neither is a completion or a verification condition; the operator was not
changed (the seed state is now readable for one).

### 7.4 When a re-seed by merge dump cannot repair

The merge dump (the fallback whenever snapshot push declines — a
destination with > 4096 items, a different partition count, a non-RocksDB
side) iterates the SOURCE's keys and sends a versioned set for each. On a
populated destination:

| destination state | merge dump result |
|---|---|
| key missing (dropped set) | STORED — repaired |
| key at an older version (dropped overwrite) | STORED — repaired |
| key present, source deleted it (dropped delete) | **never touched**: the dump sends no deletions — stays wrong |
| key present at the same version | NOT_STORED, which the dump counts as a failure; 64 in a row abort the dump (handler_dump_replication.cc) — **a merge dump over a populated, mostly-correct destination aborts by construction** |
| key present at a NEWER version (written on the destination, or another lineage) | NOT_STORED — the source's value never lands; counted as failure |
| expired on the source, present on the destination | the source skips it (get → not found); the destination expires it at the same absolute time unless its clock differs |

So: re-seeding a populated destination needs it EMPTY first (then snapshot
push copies whole files, or the merge dump runs onto nothing). A
destination with ≤ 4096 items is replaced by snapshot push WITHOUT an
explicit wipe (the fresh-target guard's threshold) — itself destructive,
existing behaviour, not changed.

### 7.5 Minimal specification — two separate procedures

**V. Non-destructive verification before a cutover (no data is changed).**
Not implemented as a tool; nothing here is exercised by a test.

1. Writes stopped: the web/app write path closed (human), then on EVERY
   source partition master `cmd_set`, `delete_hits + delete_misses`,
   `touch_hits + touch_misses`, `incr_*` / `decr_*` unchanged over ≥ 60 s.
2. Forwarding drained: on every source master the accounting identity in
   7.2 closes (`forward_enqueued` = sum of outcomes; nothing in flight), and
   the forwarding threads' queues are 0 (`stats threads`).
3. Seed: `cluster_replication_seed` is completed_* on every source master
   (failed_* or connecting → refuse).
4. Drops: any `proxy_write_dropped[<destination>]` or
   `cluster_replication[forward_failed_*|dropped_*]` above the value read
   when the seed completed → a divergence is known → step 5 still runs (to
   list it) and the cutover is refused.
5. Per-key comparison, per partition: stream the source master's and the
   destination master's keys (e.g. the `dump` command flared serves for
   reconstruction — that it has no side effect when used this way is not
   re-checked here), sort, compare key sets (missing / extra),
   value bytes, flags and absolute expiry; keys expiring within a margin of
   the comparison are excluded on both sides. A count or a digest is not
   enough on its own (7.3: equal counts with wrong content).
6. Verdict: zero missing, zero extra, zero mismatches → the cutover MAY
   proceed (still a human approval); anything else → refuse, keep the
   difference list.

**R. Repair — destructive, only with explicit approval, never automatic.**

- R-a full re-seed: approval recorded → source `enabled: false` (applied:
  `cluster_replication off` on every source pod) → destination emptied (its
  data dir / tmpfs; a cluster recreate) and `curr_items` 0 confirmed →
  `enabled: true` → `cluster_replication_seed` completed_snapshot_push on
  every source master → V from step 1. Not exercised end to end; the
  re-enable onto a ≤ 4096-item destination is (E2E cluster-replication-
  reseed).
- R-b targeted: from V's difference list, re-set missing/older keys from
  the source (versioned sets), delete extra keys on the destination —
  approval per list. Not implemented.

Neither R-a nor R-b is triggered by the operator or flared. Reseed alone
is not a verification (7.4), and verification alone repairs nothing.

### 7.6 Results

| test | old code (50f65f1, E2E 38120285667) | new code |
|---|---|---|
| DNS unresolvable at enable (1) | pass: early 0 arrived / 10 counted, late 20/20 | pass (4024a6c 38120334275, b573101 38122732042, 73e7252 38124283442): early 10/10 and late 20/20 ARRIVED, 0 counted (ridden out); the seed retried and completed by snapshot push (4 connect attempts) |
| connection broken 4× by the destination (2: arrived-or-counted, 3: final match) | pass / pass: 8 connections closed, 24 tracked keys (16 new, 4 overwritten, 4 deleted), 0 differ, 0 counted — the 4 quick retries survive a closed connection | pass / pass in all three runs: 24 keys, 0 differ, 0 counted; accounting shows forward_retried 10, forward_noop_set_not_stored 30 (the snapshot already held them) |
| destination master restart, data kept, back after ~17 s (4, 5) | **FAILED both: SILENT LOSS** — 21 of 30 tracked keys differ (every delete and overwrite of the pre keys, …), 0 drops counted; the restarted destination answered SERVER_ERROR, which this code only logs 1 in 100 | **FAILED both, for a different reason (prediction NOT met)**: the destination never got a master back. With the seed now completing (snapshot push), the destination copy holds the SOURCE's history; on restart the destination operator FORBIDS it (`rejoining: the copy holds 803c2472…/2:6307281b…, not the authoritative history`) and holds partition 0 masterless (`CRITICAL: partition 0 has NO master`); data kept (curr_items 60), flared re-registered as a Prepare slave with no source. The source counted what it could not deliver (`SERVER_ERROR no partition available` → counted; the source operator's CRITICAL: 25 drops). The SERVER_ERROR resend (5345666) is therefore NOT exercised against a returning destination yet. 73e7252 38124283442 |
| re-enable after a snapshot-push seed (6) | **pass — the predicted rollback did NOT happen in this order**: after the first seed the destination's master_id WAS the source's (26b434b0-…, both), so the master_id guard no longer applied; the WAL exchange was refused for another reason — `WAL sync refused (lsn_purged)` (the destination could not serve from the source's LSN 0); the snapshot push then re-seeded (K=new on both) | pass (4024a6c, b573101): no WAL exchange; snapshot push re-seeded, K=new on both, seed state completed_snapshot_push |

**New finding (not caused by this round's change, exposed by it):** a
destination seeded by snapshot push cannot get its master back after that
master restarts. The pushed files carry the source's history identity;
the destination cluster's authoritative-history gate (SAF-10b) treats the
returning copy as foreign and holds the partition masterless — writes to
the destination fail until a human acts (RUNBOOK #history-held-masterless).
On the old code this suite never seeded (the seed's first connect failed
and was not retried), which is why its restart came back in 17 s. For the
Monday ingest via snapshot push this means: ANY restart of a destination
master before the cutover takes the destination down. **Decision needed**
(authority rules, not changed here): e.g. the destination operator adopts
the history a snapshot push brought as a recorded re-seat, or the
procedure re-approves it after every seed. Until then the restart test
cannot exercise the SERVER_ERROR resend; a destination seeded by the merge
dump (keeps its own history) would — not run yet.

The rollback hypothesis is NOT confirmed: with equal master ids, what
stood between the source and the destination's WAL in this run was the
destination's WAL retention (lsn_purged). Whether a destination that still
serves its WAL from the source's position lets the old code apply it is
not tested (it would need the destination's WAL from its first sequence).
The removal stands on the direction alone (a seed must not write the
source); its necessity is from code, not from an observed rollback.

## UNKNOWN

- whether a blocking connect to a black-holed LB address reaches the
  fail-fast path (kernel ETIMEDOUT) or holds a thread;
- what a delete of a missing key returns behind an LB;
- whether the operator's enable → Dumping path waits for anything on the
  destination.
