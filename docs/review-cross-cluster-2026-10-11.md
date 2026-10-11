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
Superseded by §8 (implemented as an offline comparator; corrections there).
Kept as first written, with the step corrected in review:

1. ~~Writes stopped: … unchanged over ≥ 60 s.~~ **Corrected (review
   2026-10-11):** counters unchanged for 60 s are NOT a write fence — a
   client may write at second 61. V takes the write stop as an EXTERNAL
   premise (the client path closed by a human) and only checks that
   nothing changed DURING the scan: identity, copy, history, position and
   mutation counters before vs after, on both sides (§8.2).
2. Forwarding drained: on every source master the accounting identity in
   7.2 closes (`forward_enqueued` = sum of outcomes; nothing in flight), and
   the forwarding threads' queues are 0 (`stats threads`).
3. Seed: `cluster_replication_seed` is completed_* on every source master
   (failed_* or connecting → refuse).
4. Drops: ~~above the value read when the seed completed~~ **Corrected:**
   a baseline at seed completion misses losses DURING the seed; the
   baseline is read before replication is enabled for the attempt and the
   whole attempt is compared; a restart or counter reset loses the
   comparison → Unknown (§8.2).
5. Per-key comparison, per partition: stream the source master's and the
   destination master's keys (e.g. the `dump` command flared serves for
   reconstruction — **it has side effects, §8.1**), sort, compare key sets
   (missing / extra), value bytes, flags and absolute expiry;
   ~~keys expiring within a margin are excluded~~ **Corrected:** excluding
   them can manufacture a zero difference; they are indeterminate and force
   Unknown (§8.3). A count or a digest is not
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

## 8. Verification V, implemented (offline comparator) — third round 2026-10-11

`scripts/flare_verify_copy.py` (711b449), fixtures
`scripts/tests/test_verify_copy.py` (24 tests, CI step "Test verification
V"). It reads FILES: captured `dump` replies and `stats` snapshots. It does
not connect to any server, changes nothing, repairs nothing. Its only
outputs are a report (difference list) and a verdict that refuses the
cutover (exit 1 DIFFERENT / 2 UNKNOWN) or says it MAY proceed (0 MATCH —
still a human approval). No live scan was run anywhere; capture on a real
environment is not approved.

### 8.1 What `dump` does to the node it is served on (code)

| effect | where |
|---|---|
| a live `get()` per emitted key; on a partition MASTER (`_lazy_expiry_delete`, set for role master, cluster.cc:2285) an expired key is DELETED (a WAL write, `rocksdb_expire_reaped`++); TCH deletes on any role | op_dump.cc:237, storage_rocksdb.cc:1974-2016, storage_tch.cc:478-500 |
| holds the storage's single iteration slot for the whole run: a concurrent reconstruction served from this node, a cross-cluster seed, orphan scan/purge, `dump_key`, another `dump` get `SERVER_ERROR database busy` | storage_rocksdb.cc:2366-2397; handler_dump_replication.cc:230; op_orphan_scan.cc:93 |
| RocksDB `_mutex_wholelock` read-held until the end (with `wait`/`bwlimit` sleeps): flush_all/truncate, copy switch, staging adopt, reopen wait for it | storage_rocksdb.cc:2369, 2244, 809, 1067, 2932 |
| keys from a snapshot iterator, VALUES live (no snapshot on get); TCH has no snapshot | storage_rocksdb.cc:2384-2392, 1950 |
| no cmd_get / hit-miss stats; "serve" peak samples (I/O on large dirs) | op_dump.cc:216, 225 |
| framing `VALUE <key> <flag> <len> <version> <expire>\r\n<len bytes>\r\n … END\r\n`; values length-prefixed (binary-safe); expire absolute unix time (0 never) | storage.cc:221-238 |
| partition filter `dump <wait> <p> <n>`: hash(key) by the cluster's algorithm → `key_resolver_modular`; safe values `0 ≤ p < n < capacity` (rc57 OOB fix rejects others with `ERROR`) | op_dump.cc:85-185, 226-233 |
| no access control on the flared port | op_parser_text_node.cc:114-117 |

Consequences: capture is not side-effect free and is NOT approved on any
live environment. On a master, an expired key met by the dump moves
`rocksdb_expire_reaped` and the sequence number — the tool then reports
the scan invalid (UNKNOWN) and a rerun is needed; a dataset that keeps
expiring may never give a valid scan (UNKNOWN, refused — by design, not a
pass). Capture must not overlap a reconstruction, seed or orphan scan on
that node (they would fail "database busy").

### 8.2 Validity of one scan (all must hold, else UNKNOWN)

- Write stop: an EXTERNAL premise (client path closed by a human). The
  tool does not prove it; unchanged counters are necessary, not sufficient.
- Every node, pre vs post snapshot: same pod UID and process start
  (`time - uptime` ±2 s); `rocksdb_master_id`, `rocksdb_copy_id`, copy
  epoch (`rocksdb_rebuilt_from_epoch` / `rocksdb_source_epoch`),
  `rocksdb_latest_sequence_number` unchanged; `cmd_set`, delete / touch /
  incr / decr / cas counters, `curr_items`, `rocksdb_expire_reaped`
  unchanged. Any missing stat → UNKNOWN (so a TCH node, without the
  rocksdb_* identity, is always UNKNOWN).
- One dump stream per partition master on each side; each stream complete
  (END), framed, no error reply, keys strictly increasing (RocksDB
  bytewise order); a key in two partition streams of one side → UNKNOWN.
- Loss over the whole attempt: baseline = the source masters' stats read
  BEFORE replication was enabled for this attempt; post = after the scan.
  `proxy_write_dropped` + `cluster_replication[forward_dropped_* |
  forward_failed_* | forward_missing_* | seed_failed]` moved → DIFFERENT
  (a known loss, whatever the scan says). Baseline read with replication
  already on, a restart or replaced pod, a counter that went down, a
  master set that changed → UNKNOWN. Every source master must have
  completed a seed in this attempt (`seed_completed` above the baseline,
  state completed_*).

### 8.3 Comparison and the expiry reference

Merge-join of the two key-ordered streams, streaming (memory O(1) plus the
first 50 samples per class). Both present: value bytes, flags, absolute
expire, version must be equal (a version difference is a difference).
One side only — the reference time: each side omits what had expired BY ITS
OWN CLOCK when it read the key, inside its scan window [server `time` at
pre, at post]. A one-sided key that never expires, or expires after the
other side's window end + skew (skew = 2 × the largest |server time −
capture time| seen + 1 s), is a definite missing/extra. Otherwise it may
have expired there before being read → INDETERMINATE → the verdict is
UNKNOWN. Nothing near expiry is excluded.

### 8.4 Not checked by the tool

That each key belongs to the partition of its stream (the server's `dump`
filter is trusted); the write stop itself; in-cluster slaves (only the
partition masters, which serve clients, are compared); TCH.

### 8.5 Fixtures

Built from fixed bytes, no cluster, no clock: the exact op_dump wire bytes
(test_op_dump.cc), a binary value containing `\r\nEND\r\n` and a fake
header, 2 source partitions vs 1 destination; delete not applied (extra),
missing, value / flags / expire / version each different, one-sided key
expiring after vs inside the window, clock offset widening the band; six
stream defects; duplicate key across partitions; stream count ≠ masters;
eight change-during-scan cases (sequence, copy id, master id, epoch,
cmd_set, delete_hits, expire_reaped, missing stat); restart during the
scan; stats without END; restart / late baseline / counter reset / seed
not completed over the attempt; loss during the seed; counted loss with
matching content (DIFFERENT); differences from an invalid scan (UNKNOWN,
listed); lazy streaming.

## 9. FlareMigration: the count gate led to a client-visible switch (637bb7a)

Traced (Migration/Types.lean, Controller.lean, cluster_replication.cc):
Duplicating → Forwarding fired when the target's summed `curr_items` ≥
the source's for 6 ticks, with NO approval, and `switchForward` puts the
source flared in forward mode: every client read and write reaching the
source is proxied synchronously to the target and answered from it;
op_set / op_delete / op_incr skip local storage. So equal counts (wrong
values, missing deletes, a seed that never ran, 0 = 0 counted during
Provisioning) switched the client data path. Also: abort was allowed in
Forwarding / AwaitingCutover, and doAbort deletes the target — which by
then holds acknowledged writes the source does not. Cutover (Service
selector) and retire (source STS + CR delete) were already behind
approvals; the RUNBOOK's "forward mirrors only live writes" was wrong.

Fix (637bb7a): the switch needs counts converged (counted only while
Duplicating), this attempt's seed completed on every source master,
loss clean over the whole attempt (baseline before enable; Unknown =
held), AND `spec.approveForward` (after V). Abort refused from Forwarding
on. Theorems `migStep_forward_requires_approval_and_evidence`,
`migStep_no_abort_after_forward`; 22 unit checks, the first of which
("equal counts alone do NOT switch to forward") fails on the old step
function by its code (old: `if convergedTicks ≥ 6 then switchForward`) —
not run against the old code. E2E blue-green-migration now requires the
hold without approval and the switch with it: **38140891471 (637bb7a)
11/11 PASS** — held with "counts, seed and loss counters satisfied — NOT a
verification", baseline read with replication off on both source masters,
moved only after approveForward; cutover, retire, self-retire, abort pass.
Not run against the old operator (the unit check above is the control, by
code). No wipe or reseed is triggered by any of it.

### 9.1 What approveForward does NOT prove, and the binding

approveForward is a boolean: the operator has no way to know WHICH
verification a human looked at. A MATCH from V is about one attempt, one set
of partition masters, their copies, histories and positions AT THE END OF
THE SCAN. The V report now carries that as `binding` (`attempt=<status.
attemptBaseline>|src=<pod,uid,start,master_id,copy_id,epoch,seq>;..|dst=..`).
The pure check `forwardBindingHold` (Types.lean) refuses the switch when the
binding is from another attempt (stale or reused), a master was added /
removed / restarted / replaced, a copy or history changed (re-seed), or a
sequence number moved (a write — or a reap — after the scan). Negative unit
tests: other attempt, write on source, write on target, source restart,
target replaced, target copy / history changed, master added / missing,
malformed (9 checks); comparator fixtures: same key count with one wrong
value, same count with a missed delete + a missing key (both DIFFERENT),
binding contents and its change with attempt / position.

**Connection points — fourth round (2026-10-12):**

| | before | now | still open |
|---|---|---|---|
| (a) what the approval is | `approveForward: true` | `spec.forwardApproval` = the line V prints **only for a MATCH**: `v=1\|verdict=MATCH\|verified_at=<source server time after the scan>\|attempt=<status.attemptId>\|src=<pod,uid,start,master_id,copy_id,epoch,seq>;..\|dst=..`; `approveForward` is read only to say it is NOT accepted | the line is not signed: a person can type one; the operator can only check it against the live masters |
| attempt | the baseline string | `status.attemptId` = `<FlareMigration uid>/<hash of attemptBaseline>`, minted in the tick that enables duplication, never changed | — |
| (b) checked at the switch | no | the controller reads every source AND target partition master (pod UID, `time − uptime`, `rocksdb_master_id`, `rocksdb_copy_id`, `rocksdb_rebuilt_from_epoch` / `rocksdb_source_epoch`, `rocksdb_latest_sequence_number`) in the Duplicating tick; `approvalHold` refuses: not a MATCH line / other version, another attempt or no attempt id, a master added / missing / named twice, a restart (start time beyond ±2 s) or replaced pod, master id / epoch / copy id changed, a moved sequence number, older than 3600 s or in the future of the source clock, any master unreadable or no clock (fail-closed) | — |
| (c) switch window | not seen | the SAME check again once the source applied forward mode: Forwarding → AwaitingCutover only if every position is still the bound one; else held in Forwarding ("re-run V and set a new forwardApproval") | between the check and the apply a write IS forwarded (the source still duplicates), but the switch is already issued and abort is refused: the hold makes it visible, it cannot undo it. Writes must stay stopped from before the capture until AwaitingCutover — the operator's premise, never observed as a fence |
| (d) capture | none | §12: `repl_snapshot` + `flared --dump-checkpoint` (no reap, point in time), CI-only driver | not approved for any real environment |
| (e) reuse | a bool stays true | an approval is bound to one attempt id and one set of positions; after the switch the phase moves on and it is never read again; a recreated migration has another uid → another attempt | no explicit "consumed" record |
| meaning of "resume" | — | after AwaitingCutover the gate is no longer consulted: writes may resume; any write before that voids the approval (positions move) | — |

Proofs: `migStep_forward_requires_approval_and_evidence` now concludes
`approvalHold spec.forwardApproval obs = none` (not a boolean);
`approvalHold_none` unpacks it (parsed MATCH, every master readable, age
bounds, `forwardBindingHold … = none`); new
`migStep_awaitingCutover_rechecks_approval`. Unit negatives (477 checks):
no approval; boolean only; DIFFERENT / UNKNOWN / other version / bare
binding; another attempt and no attempt; same count with a wrong value
written on the target after the MATCH (target position moved); write on the
source; source restart, target restart, target pod replaced; target copy /
epoch changed; unreadable master / no clock; too old / future; a binding
naming one master twice cannot cover a second; Forwarding held when a write
lands in the switch window on either side; a new MATCH bound to the new
positions advances; one GOLDEN line produced by the comparator test and
parsed by the operator test. E2E (blue-green): a boolean is not accepted; a
real capture with one target value altered (same key count) → DIFFERENT and
no approval line; a real MATCH used after one more write → held "position
moved"; a fresh MATCH edited to name another attempt → held "another
attempt"; the same fresh MATCH → AwaitingCutover — run listed in §14.

A comparator pass does not prove its inputs: that the captured dumps are
complete for every partition, that counters not in the snapshot did not
move, that the server-side partition filter was right, and that expiry was
read on the clocks assumed — these stay premises (§8.2–8.4).

Not changed: what V or a human does with a refusal; `proxy_write_dropped`
also counts in-cluster drops (a hold may be conservative); no automated way
back from forward mode.

## 10. A snapshot-push seed as an authority transition — proposal only

**What happens today (code, review agent audit):** the destination's
history record lives in ConfigMap `<cr>-history` (`part <p> known <gen>
<masterId> <epoch> <holder> <podUid> <bootId> <copyId> <since> <reason>
<hold>`). `swap_in_snapshot` on the receiving master adopts the SOURCE's
master_id and source epoch (reason `inherited`) and mints a NEW copy id
(`uuid:1`). The operator's transitions: `rebind` needs the same copy id;
`bulk` needs the same uuid prefix and a receipt chain — a different prefix
returns `.none` (AuthoritativeHistory.lean:260): no hold, no log. So the
record silently goes stale at the push; replica rebuilds are refused ("not
the recorded holder with its copy"), and the first restart of that master
is FORBIDDEN (rejoining) → masterless (§7.6, X4). The push carries no
attempt id, no source cluster identity, no approval (op_repl_snapshot_push
skips the source master_id token).

**Comparison with what exists:**

| | receipt before the change | receipt after | crash in between | approval |
|---|---|---|---|---|
| bulk (flush_all) | flared `__flare_bulk_pending = pred epoch` | `__flare_bulk_chain` pred→succ@epoch, same synced batch as pending removal | recover at open: finalise if epoch advanced, else stays pending (operator HOLDs) | none (same copy lineage) |
| restore (RESTORED / RESTORE.switch) | `.flare_restore_pending` sentinel; `restore-<attempt>` intent | new copy id + `__flare_restored_unverified` | incomplete → discarded at open; replaced copy retained | no history transition exists (R8 open) |
| promotion (operator) | intent persisted in `<cr>-history` before the map commit | `transition=<id>` in the committed map; record gen+1 | resolveIntent against the persisted map | the commit itself |
| copy discard | FlareCopyDiscardApproval (requestId, podUID, copyId, expiry) | flared ledger answers repeats | `already:started` → Unknown, never re-run | per request, one use |
| **snapshot push** | `.flare_restore_pending` only (data); nothing about identity | none | data discarded at open; operator learns nothing | **none** |

**Minimal proposal A — recorded seed receipt (code change, not made):**

1. Approval: a one-use `FlareSeedApproval` (pattern: FlareCopyDiscardApproval)
   on the DESTINATION: destination cluster UID, partition, holder pod UID,
   the holder's CURRENT copy id and history (the "from"), the source
   cluster's identity (name + its history id), attempt id, expiry. The
   destination operator relays it to flared (`seed_accept <attempt>
   <fromCopy> <sourceMid>`); flared refuses a SNAPSHOT push without a
   matching, unexpired acceptance (answers `not_approved` → the source's
   seed state `failed_transfer` — seen, not silent).
2. Receipt on flared, same pattern as bulk: before the old DB is removed,
   persist `__flare_seed_pending = attempt fromCopy fromMid/fromEpoch
   sourceMid/sourceEpoch`; in the synced batch that writes
   `__flare_repl_restore_done`, write `__flare_seed_receipt = attempt
   fromCopy→newCopy fromHist→newHist source completed` and drop the
   pending key. At open: sentinel present → data discarded AND receipt
   `failed <attempt>` (no adoption); pending with restore_done = cp_seq →
   finalise. Exported in stats (`rocksdb_seed_receipt`).
3. Operator transition `seed` (new reason): record `known`, no hold, the
   holder unchanged (pod UID; the boot may differ), receipt observed on
   that holder with `from` = the recorded copy + history, `to` = the
   observed copy + history, attempt = the approval's, completed → gen+1,
   hist := the source's, binding := new copy, approval consumed. Any
   mismatch → HOLD with the reason logged (replacing today's silent
   `.none` for a different uuid prefix). Never adopts a change it did not
   see a receipt for; never relaxes FORBIDDEN for anything else.
4. Restart cases: approval present but no push → expires, nothing adopted;
   push interrupted → data discarded, receipt failed, record unchanged
   (holder's old copy is gone: HOLD, human); push completed, operator down
   → the receipt persists on flared, adopted when observed; master
   restarted after completion but before adoption → the receipt is on
   disk, same pod UID → adopted; pod replaced → HOLD.
5. Tests needed: the X4 restart test (cluster-replication-faults T4/T5)
   must then pass with the approval; without it the push is refused; a
   receipt for another attempt / another holder is refused; crash points
   between pending, swap and receipt (C++), operator restart mid-way (E2E).

**Proposal B — re-approval after every seed (operations, smaller code):**
after the source reports `completed_snapshot_push`, a human checks that the
destination master's `rocksdb_master_id` / epoch equal the source's and
its copy id is the one just minted (`rocksdb_snapshot_bootstrap` moved,
pod UID unchanged), then sets a one-use annotation
`flare.gree.net/history-reseed-approved=<uid>/<p>/<copyId>/<mid>/<epoch>`;
the operator applies gen+1 reason `reseed` only if the observed holder
matches every field exactly, else ignores it and logs. No flared change;
the gap between the push and the approval stays (a restart in it =
masterless, RUNBOOK #history-held-masterless).

| | A: seed receipt + one-use approval | B: re-approval after each seed |
|---|---|---|
| code | flared (accept op, pending/receipt keys, recovery at open, stats), operator (relay, new transition, hold instead of silent `.none`), new CRD, C++ crash tests + E2E — large | operator only (annotation, exact-match transition, log); E2E — small |
| unprotected window | none after the receipt is durable; a push without approval is refused | from the push until the human approves: a destination master restart = masterless (data kept; RUNBOOK #history-held-masterless) |
| crash recovery | defined per point (pending / sentinel / receipt; adoption from the on-disk receipt after a restart) | nothing to recover; a restart before approval needs the existing masterless runbook |
| during the move | source seeds only into an approved destination; history follows by itself | every seed (initial, any re-seed R-a) needs a human check of master_id / epoch / copy id and an annotation |
| record format | new reason (`seed`) | new reason (`reseed`) |

Recommendation (not a decision): B for the move — small, operator-only,
every adoption a human act bound to exact identities — with the move's
procedure forbidding destination restarts between push and approval; A as
the durable fix afterwards. Both are NOT implemented. Choosing between them — and the record format
(a new reason value means format 2 → 3, which an older operator reads as
corrupt) — waits on the compatibility decision, which is pending
(old-backup compatibility is not approved either). Neither relaxes the
FORBIDDEN rule after seeds in general. Until then the snapshot-push
restart test (cluster-replication-faults T4/T5) stays failing and is NOT
replaced: the per-key-seed suite (§11) only isolates the SERVER_ERROR
resend.

## 11. Per-key-seed restart (isolated SERVER_ERROR resend fixture)

Suite cluster-replication-restart-dump (51d17e7): the destination is
pre-filled with 4300 keys (> fresh threshold 4096) so the push declines
`not_fresh` and the seed is the merge dump (the destination keeps its own
history); then the same restart as faults T4. Verdicts: arrived-or-counted;
order reached (`forward_server_error_retried` moved — else the resend was
not exercised and this FAILS); final per-key match.

| run | code | precondition (per-key seed) | arrived-or-counted | order reached | final match |
|---|---|---|---|---|---|
| 38140445297 (51d17e7) | new, no operator hold | reached (completed_dump, bootstrap 0) | pass (30/30, 0 counted) | **FAIL — not reached**: back in 22 s, `forward_server_error_retried` 0 (connection-level retries 2) | pass |
| 38142537078 (054e373) | new, destination operator held 45 s | reached | pass: 0 differ, drops 0 → 0 | **pass: SERVER_ERROR resent 2**; applied 30 = enqueued 30 | pass (30/30) |
| 38142587820 (e526e61 = b939777 tests + 50f65f1 C++) | OLD, operator held | reached (old code has no seed stat: "dump replication completed" log + bootstrap 0) | **FAIL — SILENT LOSS: 29 of 30 differ, 25 counted** (connection failures after 4 retries, "DROPPED after 4 retries" logged) | fails, but meaningless on old code (counter does not exist) | FAIL |

Old-code control, attribution (fourth round): the 25 counted drops equal
the 25 changes written while the destination was down (15 new, 5
overwrites, 5 deletes; connection refused → "DROPPED after 4 retries"). 29
differ, so 4 of the 5 post-return keys (`rst_post_*`, written after the
destination answered `stats` again) were lost UNCOUNTED. Evidence: the
source logged `rst_post_1 … ANSWERED but not stored … result=SERVER_ERROR`
(throttled 1 in 100, so only the first is named), the restarted destination
logged `no partition is available` 5 times, and `forward_server_error_
retried` does not exist on the old code. So the failure is the targeted
defect (a SERVER_ERROR answer from a destination that listens without a
role is neither resent nor counted), not a harness problem; which 4 of the
5 post keys is not established per key (the failure message lists 10 of the
29). Note: the old code never answered SERVER_ERROR during the 45 s hold
("restarted flared lines about no partition: 0" at that moment); the
answers came after the hold, before the role arrived — on the new code the
same phase produced 2 resends. This closes the SERVER_ERROR-resend evidence for a
per-key-seeded destination only. It does NOT close X4: the snapshot-push
restart (cluster-replication-faults T4/T5) still fails and stays.

## 12. Capture without changing the master (audit, fourth round)

Question: is there an existing read of a master's complete content as one
point in time that changes nothing? Answer: **no single existing op; two
existing pieces combine into one with no change on the serving side**
(code audit, file:line in the audit notes):

| path | point in time? | changes the master? | expired keys | gives flag/version/expire/value? |
|---|---|---|---|---|
| `dump` | NO — keys from a snapshot iterator, values read live (`get`, op_dump.cc:237) | YES — reaps each expired key met (WAL write, `rocksdb_latest_sequence_number` and `rocksdb_expire_reaped` move); takes the single iteration slot (concurrent dump / orphan scan / dump-replication seed get "database busy"); holds the whole-DB read lock for the scan (blocks flush_all, copy switch, adopt_history, swap_in_snapshot, resets); the held snapshot pins old versions (space; memory on tmpfs) | hidden (and deleted on a master) | yes |
| `dump_key`, `orphan_scan`, dump-replication | same as dump | same | — | no values / counts only / pushes sets |
| `backup <name>` | yes (checkpoint) | YES — prunes old backups to backupKeep−1; pins space (rc47 OOM) | included | files on the pod |
| **`repl_snapshot`** | **yes** — RocksDB checkpoint at a reported sequence number | no data write, no reap, no iteration slot, lock only briefly; costs: a forced memtable flush, file deletions pinned for the transfer (WAL / old SSTs accumulate), hard links pin space until the stream ends (memory on tmpfs), the single snapshot-serve slot (a concurrent reseed waits "busy"), the transfer (throttled by rocksdb-snapshot-bwlimit) | included with absolute expire | raw RocksDB files |
| `flared --analyze-checkpoint` (offline) | — | never connects | included | key, expire, size only |

Minimal implementation made (CI-only use):
- `flared --dump-checkpoint <dir>` (storage_rocksdb::dump_checkpoint, ~70
  lines): opens a checkpoint READ-ONLY and writes every non-reserved key in
  the `dump` framing (`VALUE key flag size version expire` + bytes), keys and
  values from the same checkpoint, expired-unreaped keys included; a value
  whose size disagrees with its header fails the run (no END). C++ test
  `test_dump_checkpoint_point_in_time_and_side_effect_free`: a write after
  the checkpoint is absent, binary value byte-exact, blob value, flag /
  version / absolute expire kept, an expired key included, reserved keys
  filtered, the master's `expire_reaped` and latest sequence number
  unchanged by checkpoint + decode.
- `scripts/flare_snapshot_receive.py`: receives one `repl_snapshot` stream
  into an empty directory; refuses an error reply ("busy"), a short file, a
  CRC-32 mismatch, a suspicious or repeated name, a missing END, a file
  count that disagrees (10 fixture tests, in CI).
- `scripts/flare_v_capture_kind.py`: stats before → per master
  `repl_snapshot` (`quit` pipelined so the connection closes) → receive →
  copy into the pod's /tmp → `--dump-checkpoint` there → remove → stats
  after. **Refuses any kube context not named `kind-*`** (checked against
  the local default context, which is a real cluster: refused, exit 3).
- Comparator: unchanged framing; expired-unreaped keys present on both
  sides compare exactly; reaped on one side only → INDETERMINATE → UNKNOWN
  (2 new fixtures).

Still not guaranteed by this capture: no partition filter (every key the
copy holds, orphans included — an orphan duplicated across two source
streams is reported UNKNOWN, never merged); the expiry reference is each
side's stats time around the capture (the checkpoint's own clock is not
in the `SNAPSHOT` line); a slow receiver holds the pin longer; refused on a
restored-unverified copy; whether the forced flush moves the sequence
number is checked by the C++ test above (hypothesis: it does not), and on
kind by the pre/post stability check. Load / permission for a real
environment: `repl_snapshot` is an unauthenticated op on the data port like
`dump`; the capture costs one checkpoint (space ≈ the live SST + blob set
until the stream ends, on tmpfs = memory) and one full transfer per master.
Running it anywhere real is an operational approval that has not been
given.

## 13. Snapshot-push authority: the failure window of each option, and the one decision

B's "no destination restart between push and approval" is a request to
the world, not a safeguard. What actually happens if the destination
master fails in that window, today (code + faults T4/T5): its history
record is stale; on restart the operator classifies the copy FORBIDDEN
(rejoining) and the partition stays masterless — the copy is kept on the
PVC, nothing is promoted, nothing is deleted; the source keeps serving
clients (duplicate mode) and every forward to the destination is resent
for 120 s, then counted as dropped (not silent). Recovery under B after a
human approval: the approval must name the copy actually on the PVC
(uid / partition / copy id / master id / epoch) — if it is still the pushed
copy, the operator records `reseed` and promotes it; the drops counted
while it was down must then be repaired: R is not implemented, so the
repair is a re-seed — another push, another approval. So B is "safe stop,
manual recovery, one more seed per failure".

A's windows, stated without "none": (1) approval written, push not
started → nothing changed; expiry. (2) push streaming / staged, not
switched → the copy-retention staging is discarded at open (existing,
tested); old copy and old record still agree. (3) the switch itself: the
existing copy switch is crash-safe (switch markers; an unresolved switch is
FORBIDDEN — data kept, held). (4) **switched, receipt not yet durable**:
the proposal of §10 writes the receipt in a separate batch after the swap —
a crash there leaves a new copy with no receipt = held masterless, the same
as B's window. Integration that closes (4): write the receipt INTO the
staged copy before the switch, so the atomic switch brings copy and
receipt together (present ⇔ switched), and record the operator side as a
two-phase intent like promotion (`seed` intent in `<cr>-history` BEFORE the
push is allowed, resolved when the receipt is observed; a restart of the
operator resolves the intent against the observed copy, as resolveIntent
does). Remaining A windows: the intent written but the history ConfigMap
update conflicting (retry; held meanwhile); a receipt naming another
attempt / another "from" (held); bugs in the switch on tmpfs vs PVC
(covered only by the existing copy-retention tests). Every one of these is
"held, data kept" — not "no window". None of A is implemented.

A third way removes the transition from the move entirely: **seed the
destination per key only (no snapshot push) for the move.** The destination
keeps its own history, so a restart is an ordinary master restart — the
case §11 now passes (0 lost, SERVER_ERROR resent). Costs: seeding speed
(rc28 measured a SLAVE reseed: 166 s by dump vs 28 s by snapshot, ~5.9x;
a cross-cluster seed was not measured), and the per-key
seed runs `dump` on the SOURCE master (reaps, iteration slot, whole-DB read
lock for the seed's duration — §12). Needs a small flared/operator switch
to decline pushes (not implemented; today only a destination above 4096
items declines, which is not a control).

**The one decision:** for the move, may the destination's authoritative
history change at a snapshot push at all?
- **No (recommended for the move):** per-key seed only; implement the
  decline switch; A/B stay unimplemented; X4 stays open as a known failure
  of a path the move does not use (T4/T5 keep failing, not replaced).
- **Yes:** then A with receipt-in-staged-copy + operator intent (needs the
  record-format / compatibility decision: a new reason value is format
  2 → 3, which an older operator reads as corrupt) — or B as an interim,
  accepting "safe stop + manual recovery + a re-seed per failure".

Nothing here was adopted; no rule was relaxed; old-backup compatibility
stays unapproved.

## 14. Fourth-round runs

Pending at the time of writing: the dispatched runs are recorded here when
they finish (failures and skips kept separate).

## UNKNOWN

- whether a blocking connect to a black-holed LB address reaches the
  fail-fast path (kernel ETIMEDOUT) or holds a thread;
- what a delete of a missing key returns behind an LB;
- whether the operator's enable → Dumping path waits for anything on the
  destination.
