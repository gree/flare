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

| run | code | result |
|---|---|---|
| 38145285059 full E2E | cb3d763 | all groups success except cross-cluster: faults T4 FAIL (destination master not back in 300 s: "no node partition for this slave … deactivating" — the known X4 authority gap), T5 FAIL (comparison not reached); faults T1–T3, reseed T6, restart-dump 3/3 pass. Not a harness failure, not a new cause |
| 38145287548 nix-linux | cb3d763 | success |
| 38179719906 blue-green (single suite) | 7c1de36 | **14/14 pass**: held without approval; boolean held ("NOT accepted"); real capture with one target value altered → DIFFERENT (compared 60, different 1), no approval line; real MATCH then one source write → held "position moved"; fresh MATCH edited to another attempt → held; the same fresh MATCH → AwaitingCutover (the post-apply recheck passed: no position moved while forward mode was applied), then cutover / retire as before |
| 38179722077 nix-linux | 7c1de36 | success; RocksDB build 5360 tests 0 failures, `test_dump_checkpoint_point_in_time_and_side_effect_free` ran (keys=3 seq=8); the non-RocksDB build does not contain it (expected) |

Observed in the kind captures (hypotheses before the run held there):
with writes stopped the sequence numbers did not move between captures
(source 42/42, target 70) — one extra write moved exactly one source master
(42→43) and the target (70→71); a checkpoint + decode did not move them
(pre/post stability passed). This is one kind run with keys without
expiry; a store with expiring keys reaps in the background and moves the
position (the approval then goes stale — fail-closed, not measured).

## 15. Fifth round (2026-10-12): opt-in per-key-only switch, one-use approval, capture resources

### 15.1 Opt-in switch: `spec.clusterReplication.snapshotPush: false`

Makes the per-key-only option possible; NOT a decision to use it, and the
snapshot-push history problem (§10, §13; faults T4/T5) stays open.

- flared `cluster-replication-snapshot-push` (bool, default true; reload:
  absent = true). Read by the cross-cluster seed handler
  (handler_dump_replication) when a seed STARTS: with false it never sends
  `repl_snapshot_push`, logs it, counts
  `cluster_replication[seed_snapshot_push_disabled]`, and runs the per-key
  merge dump. Stat `cluster_replication_snapshot_push on|off` while
  replication runs. In-cluster replica snapshots (`repl_snapshot`, slave
  reseed) are a different path and do not read it.
- Operator: `snapshotPush` (default true) renders NOTHING (the replication
  block is byte-for-byte the old one — unit check); false renders
  `cluster-replication-snapshot-push = false`. The desired-config check now
  includes the switch, so a toggle re-renders once.
- Hazard: an older flared rejects a config with an unknown key
  (program_options, allow_unregistered off) — opting in needs a flared with
  this option.
- E2E `cluster-replication-per-key-only` (cross-cluster group): a failed
  seed (port closed) → `failed_connect`, `seed_completed` unchanged,
  destination untouched; a seed into a FRESH destination (one that would
  accept a push) → `completed_dump`, `seed_snapshot_push_disabled` moved,
  destination `rocksdb_snapshot_bootstrap` 0 and master id / copy id / epoch
  unchanged; V (kind capture) MATCH over every key, value, flag, absolute
  expire and version, keys deleted before and after the seed absent; the
  destination master restarted (PVC kept) comes back as master with the same
  history and V MATCHes again after more changes; a source slave started
  empty still reseeds by snapshot. No C++ unit test: the handler tests use a
  non-RocksDB mock storage, where the push path never runs — the E2E is the
  test. Old-code comparison: the existing faults T4/T5 (push accepted →
  masterless after restart).

### 15.2 Approval: one use

`status.forwardApprovalConsumed` records the approval line in the same
status patch that issues the switch (a failed action does not consume it);
in Duplicating the same line is refused "(one use)". Forwarding's post-apply
recheck uses that line itself. Proof: `forwardHold_none` /
`migStep_forward_requires_approval_and_evidence` now also conclude the
approval is not the consumed one. Units 482. The status patch and the CR
patch are two writes: an operator crash between issuing the switch and the
status patch leaves the phase Duplicating with the source already patched to
forward — the next tick's check sees the same positions and re-issues the
(idempotent) switch with the same approval; it is consumed then. Not a
reuse across attempts (the attempt id differs).

### 15.3 What keeps writes stopped, and what is checked fresh

| step | who | checked by the operator |
|---|---|---|
| stop client writes | a person, outside the operator | no (a premise; only positions not moving are seen) |
| capture + V MATCH | a person, kind driver only | the line names attempt + every master's identity/position after the scan |
| set forwardApproval | a person | parsed; MATCH only; one use |
| switch tick | operator | fresh read of every source AND target master: identity, position, clock (age ≤ 3600 s); unreadable = held |
| forward applied | operator | the SAME check again before AwaitingCutover; a moved position = held in Forwarding |
| resume writes | a person, after AwaitingCutover | no longer consulted |

### 15.4 Capture resources (what is guaranteed, what is not)

| | guaranteed by code | not guaranteed |
|---|---|---|
| concurrency | ONE serve per node (`_snapshot_serving`); another `repl_snapshot` / push gets "SERVER_ERROR busy" (the driver fails, it does not wait) | a capture delays a concurrent replica reseed (it waits busy) |
| interrupted transfer | the failed write removes the checkpoint and re-enables file deletions; at the next open every `snapshot.serve.*` is removed | the release happens at the NEXT write: the throttle sleeps after each 1 MiB chunk, so it can lag the reader by a chunk's sleep; a reader that stays connected but stops reading is NOT bounded (connection_tcp's write poll loops without a deadline) — only the client bounds it (driver: `timeout 120` in the pod) |
| space | checkpoint = hard links (same fs) + copied MANIFEST/OPTIONS | no reserve is consulted before it (not implemented); compaction during the transfer turns the links into pinned space — memory on tmpfs |
| load | forced memtable flush; the transfer throttled by `rocksdb-snapshot-bwlimit` (min with the requested value) | no capacity measurement; only the kind suite below |

E2E `v-capture-resources` (r3-source group, kind, one 1×1 node, 3000 ×
200 B random values): a throttled serve takes the slot (one serve dir), a
capture started meanwhile is refused busy, the slot and directory are
released after the reader leaves (time printed); a capture under a
concurrent 3000-set write load: every write acknowledged, both write times
printed, released afterwards. Not a load test of any real size.

### 15.5 CI plan for the candidate

Targeted first (single-suite dispatch): cluster-replication-per-key-only,
v-capture-resources, blue-green-migration; nix-linux (C++ compile + cutter).
Then ONE full matrix on the pinned candidate. Known failures excluded from
any "green" claim and listed by name: cluster-replication-faults T4/T5
(snapshot-push authority, X4). Comparison with c9b59ed keeps executed
passes and skips separate (273 / 22 there).

### 15.6 Fifth-round runs on 13bde49 (full matrix, NOT all green)

- c04af30 targeted E2E 38183117517: cluster-replication-per-key-only 0/5,
  caused by the suite's own design, not the product. The full artifact log
  shows "snapshot push disabled by config … -> per-key dump". The
  disable took ~2 min to reach the pod; T2 read T1's stale failed_connect;
  the epoch advances at re-promotion by design; the source CR had no
  rebuild reserve. Fixed in 13bde49. v-capture-resources 2/2,
  blue-green 14/14, nix-linux 38183119735 success.
- 13bde49 nix-linux 38186144702: success.
- 13bde49 full matrix E2E 38186142795: conclusion **failure**. Every group
  tested 13bde49. Executed passes 290, skips 22, failures 3 (c9b59ed:
  273 / 22; the extra passes are the suites added since, not a like-for-like
  comparison).
  - cross-cluster: faults T4/T5 failed. **Known X4**, excluded from any
    green claim: the destination log repeats "no node partition for this
    slave … state=1" from 00:32:33 and the master did not come back within
    300 s. reseed 1/1, restart-dump 3/3 and **per-key-only 5/5** passed:
    - failed seed: failed_connect, completed 0→0, destination items 0;
    - seed: completed_dump, seed_snapshot_push_disabled 0→1,
      snapshot_bootstrap 0, master id / copy id / epoch unchanged;
    - V MATCH (keys, values, flags, expire, version, deletes);
    - destination restart: same master id and copy id; the epoch moved
      2→4 at re-promotion; V MATCH again;
    - a source slave started empty reseeded by snapshot
      (snapshot_bootstrap 1) with the switch off.
  - r3-source (v-capture-resources): busy refused, one serve directory,
    release ~62 s after the reader left; 3000 sets 2915 ms without vs
    3238 ms with a concurrent capture, all STORED; capture of 6851 keys.
    Kind, one node, small data: not a capacity measurement.
  - breaker-migration (blue-green-migration included): no failure.
  - **failover-data: backup-restore T24 FAILED, a NEW failure, not known
    and NOT excluded.** It passed on cb3d763 (38145285059).
    - What the logs show:
      - After the in-place restore and pod recreation, nodes-0 became
        master (epoch 4).
      - nodes-1 (slave) asked WAL sync and got epoch_mismatch (expected).
        It then opened a new connection to the same host:port 1 ms later to
        read the source copy size (`probe_source_identity`, connect timeout
        3000 ms, retry 1). Both connects failed: "Connection timed out
        (110)".
      - The rebuild PARKED with `rebuild_blocked=source_size_unknown`
        (00:31:58).
      - The operator resumed it once (00:32:00). It parked again for the
        same reason (00:32:07).
      - The operator resumes a node at most once per 5 min (Main.lean,
        `refreshParkedRebuilds`), so the replica stayed in prepare and was
        not Ready. The test's 180 s wait ended about 00:34:46.
    - Attribution:
      - The cb3d763..13bde49 diff does not touch handler_reconstruction,
        connection_tcp, the probe or the resume policy. storage_rocksdb only
        adds `dump_checkpoint`, an offline function. So no code path of
        the diff is known to be involved.
      - That is not proof the diff is uninvolved.
      - **Why a connect to a master that had just answered timed out is
        UNDETERMINED.** It is not classified as harness: no log shows a
        harness fault.
    - What it exposes regardless of the trigger: by design, two transient
      connect timeouts in the size probe turn into more than 5 min of
      replica unavailability (park, plus a 5 min resume backoff). Recorded as
      a residual; no behaviour was changed.

## 16. Sixth round (2026-10-12): T24 cause, capture guards, switch window, approval threat model

### 16.1 T24 (backup-restore, 38186142795): cause still UNDETERMINED

The single rerun 38191952092 (efb9abc, same code) passed. That does not
close T24. The earlier pass 38145285059 took 26 s against 15 s here, which
fits one park-and-resume cycle; that is unverified, because passing runs
keep no pod logs.

Established from the failing run's logs (n0/n1 = nodes-0/1 flared, op =
operator):

- The WAL-sync connection from n1 resolved and reached the NEW nodes-0
  (10.244.0.60). n0 logged that connection server-side at 00:31:51.634464
  and at 00:32:00.641611.
- About 1 ms later, the size probe (`probe_source_identity`, a fresh
  `connection_tcp`, so a second, separate `getaddrinfo`) got ETIMEDOUT
  twice per attempt, in two attempts. ETIMEDOUT here means no SYN-ACK,
  RST or ICMP within 3 s.
- During the first timeout window the operator's own connection to
  .60:12121 was reply-confirmed (op 00:31:51.7076), so the listener was
  accepting. n0 logs no accept, backlog or max_connection error.
- `util::gethostbyname` copies only the FIRST getaddrinfo result
  (util.cc:92-113). There is no cache and no nscd. The headless Service has
  `publishNotReadyAddresses: true`.
- Both pods were force-deleted together. The old nodes-0 IP was .57.

**Hypothesis (unproven):** the probe's separate lookup returned a stale
address, most plausibly the old pod's .57, whose SYNs were black-holed.
Possible mechanisms:
- per-query CoreDNS replica choice, where a replica holds a cached old
  answer (`cache 30`);
- an EndpointSlice briefly holding both addresses, of which flare takes the
  first.

Not excluded: a drop at the path or iptables level that affects only the
probe. Getting good-then-bad twice by chance is about 1 in 16.

Added to settle it next time (c989c02, 0b8c976):
- connect failures log host AND resolved IP;
- the E2E failure dump adds EndpointSlices (addresses, hostnames, ready)
  and the CoreDNS replicas and Corefile;
- backup-restore, on a recovery timeout, resolves every pod name 5× from
  every pod and prints each pod's IP.

Behaviour is unchanged. Two things are not decided here: reusing the
WAL connection's address for the probe, and iterating over all addresses.

### 16.2 Capture resource guards (0b8c976)

The kind driver now sends `repl_snapshot 0 capture 120`. flared
(op_repl_snapshot, capture mode only):

| guard | when | result |
|---|---|---|
| a rebuild in flight on the node | before any pin or flush | `capture_refused rebuild_in_flight` |
| reserve / copy size / free space unknown (tmpfs: cgroup headroom, as for rebuilds) | before | `capture_refused reserve_unset / source_size_unknown / space_unknown` |
| free < copy + reserve (worst-case pin: compaction may rewrite the whole copy while it is pinned) | before | `capture_refused no_space` |
| one serve per node | at the checkpoint | `busy` (refused, never queued); the driver captures pods one at a time |
| peer connected but not reading | while streaming | write-progress timeout 30 s → `aborted:no_progress`; socket closed |
| total duration | while streaming | min(requested, 600 s) → `aborted:deadline` (checked at the next write: up to one chunk's throttle sleep late) |
| free space falls below the reserve | while streaming (≤ 1/s) | `aborted:no_space` |
| any exit | — | checkpoint removed, deletions unpinned, slot freed; at open every `snapshot.serve.*` is removed (crash) |

Other changes in the same commit:
- The reply header carries the token `capture`. The receiver run with
  `--require-capture` refuses a server that ignored the mode (an older
  flared serves WITHOUT the guards).
- New stats: `rocksdb_capture_{served,refused,aborted,last}`.
- Decoding runs in a throwaway decoder pod (same image, no data, 50m /
  64Mi requests). It no longer copies into, or uses CPU and memory in, the
  captured pod.

Tests:
- cutter: write bounds ×3 (stalled peer → -4, deadline → -5, a reading
  peer unaffected) and the capacity rule;
- receiver: 14 fixtures;
- E2E v-capture-resources, +5 tests: no_space refused with nothing pinned;
  a stalled reader cut while still connected; total deadline; disconnect;
  kill -9 mid-capture leaves no serve directory, with curr_items unchanged.

Not guaranteed:
- **Reseed serves are unchanged.** A replica's `repl_snapshot` still has no
  write bound, so a stalled replica is not cut.
- The bound is conservative. It refuses captures on nodes with less than
  copy + reserve free.
- Check-then-act: growth between the check and the checkpoint is covered
  only by the reserve.
- The flush itself is not prevented, only gated.
- No cluster-wide limit beyond the driver's serial loop.
- Kind only. The load numbers are not capacity measurements.

### 16.3 The switch window: premise, actual gates, client-visible effects (655faa1, f5fd22b)

Facts:
- Forward mode acts in `on_pre_proxy_read/write` on the pod the client
  connects to, whatever its role. A forward-mode write is sent to the
  target synchronously; a read is served from the target.
- Duplicate mode writes on the source master; `on_post_proxy_write`
  forwards it asynchronously.
- The switch is ONE CR patch. Each pod applies it on its own
  (ConfigMap mount, up to ~2 min, then SIGHUP). `sourceForwardApplied` was
  read from the ConfigMap, so AwaitingCutover could be reached while pods
  still ran duplicate.

What a client sees when a write is NOT stopped:

| window | client-visible effect |
|---|---|
| after V, before the switch tick | acknowledged on the source, forwarded asynchronously. Not lost, but V no longer covers it. Detected: the source position moves → switch refused |
| between the switch check and the CR patch | same, detected after the apply (held in Forwarding) |
| mixed modes (some pods forward) | 1. a write through a forward pod exists on the target only; a read through a duplicate pod returns the OLD value (stale read, not detectable by positions); 2. a write through a duplicate pod reaches the target later and can land AFTER a newer forward-pod write to the same key, so the target keeps the older value. Whether the target's version check rejects it is NOT established; 3. both are detected only as moved positions; neither is undone |
| all pods forward, before AwaitingCutover | writes go to the target only. Detected (target position moves) → held |

Gates now:
1. **Before the switch**, in the same tick: every source pod reports
   `cluster_replication on`, mode `duplicate`, and no forward in flight
   (`forward_enqueued` ≤ applied + noop + missing + failed + dropped);
   unreadable = held. This is added to the approval and evidence checks.
2. **Forwarding → AwaitingCutover**: every source pod REPORTS mode
   `forward` with nothing in flight, AND the approval still holds against
   every source and target master.
3. **A forward the source already shows** (rendered, or any pod applying
   it) while the phase says Duplicating moves to Forwarding with NO action.
   This case arises when the operator crashed between the CR patch and the
   status patch. **Abort is refused in every phase once forward is seen.**
   Before f5fd22b, abort was still honoured in that Duplicating, which
   would delete a target holding acknowledged writes. §15.2's "re-issues
   the switch" no longer applies.

Proofs:
- `forwardHold_none` and `migStep_forward_requires_approval_and_evidence`
  now also conclude `podsHold "duplicate" = none`;
- `migStep_awaitingCutover_rechecks_approval` adds
  `podsHold "forward" = none`;
- new: `migStep_no_abort_once_forward_seen` and
  `migStep_duplicating_follows_seen_forward`.

Units: 486.

The PREMISE is unchanged: **writes stay stopped from before V until
AwaitingCutover**, held outside the operator. The operator only detects a
violation through positions. A stale read in the mixed window moves no
position and is not detected, so the premise is what prevents it.

Safe stop on a detected window write (RUNBOOK #migration-forward-gate):
- keep writes stopped;
- do not return the source to duplicate;
- capture and run V again:
  - MATCH → new line → advances;
  - DIFFERENT → a decision on the listed keys (repair R not implemented),
    held.

No write fence was added to flared. One would be needed to PREVENT
rather than detect: for example, sources refusing client writes until
every pod is in forward. It would block writes, so it is not implemented
without approval and not installed anywhere.

Settledness is counter-based. A non-foreign drop counted under the same
names could mask an in-flight foreign forward; this was not checked
against flared's counting paths beyond the review of
queue_proxy_write.cc:415-450.

### 16.4 The approval line: threat model and minimal measures (proposal, nothing implemented)

| actor / capability | can set `spec.forwardApproval` | can forge a MATCH line | defended by the line's binding |
|---|---|---|---|
| operator SA (patch flaremigrations + status, pods/exec) | yes | yes (reads every stat) | no; trusted by construction (it executes the switch) |
| a person with patch on flaremigrations (cluster/namespace admin; the chart defines no approver role) | yes | yes: every bound value (pod UID, start, master id, copy id, epoch, seq) is readable from `stats` on the unauthenticated data port or the API | no |
| GitOps (if FlareMigration is managed in git) | whoever merges | yes | no; the line would also have to live in git (and be overwritten on sync) |
| status writer | only the operator's ClusterRole has `flaremigrations/status` (CRD status subresource) | — | attemptId / consumed cannot be edited through the spec |

What the line DOES defend against (implemented and tested):
- a stale MATCH (age, moved positions);
- another attempt (attemptId);
- a restart, replacement, re-seed or epoch change;
- a DIFFERENT or UNKNOWN result;
- a binding that names a master twice;
- reuse (one use);
- a tampered capture (V prints no line).

What it does NOT defend against: a person who can patch the spec and
writes a MATCH line without running V. That is an authorisation problem,
not an integrity one.

Minimal measures, in order. None needs PKI.

1. **RBAC split.** Only the verifier role may patch FlareMigration (an
   optional chart Role `flare-migration-approver`). Others get get/list.
   With GitOps, keep `forwardApproval` out of git
   (`ignoreDifferences`), or treat a git merge as the approval.
2. **Audit.** Kubernetes audit log for patches to `flaremigrations`. The
   operator already logs and records the consumed line.
3. **Only if (1) cannot be guaranteed:** an HMAC over the line with a key
   in a Secret readable only by the verifier and the operator. This is a
   shared secret, not PKI, and protects against people who can patch the
   CR but not read the Secret.

Running V inside the operator would remove the human channel, but it
needs real-environment capture, which is unapproved.

Recommendation: (1) + (2), and HMAC only if the RBAC split is not
possible. That is the user's decision; nothing is implemented.

### 16.5 Sixth-round runs

- nix-linux 38194517215 (0b8c976): success, RocksDB 5364 tests and
  legacy 3628, 0 failures, 1 omission each. The four new cutter tests ran
  by name: the stalled peer was cut in 1.51 s and the deadline fired in
  1.00 s.
- E2E 38194519561 (0b8c976, 4 suites, targeted): **failure**, 13/16.
  - backup-restore 4/4 (no T24 recurrence, which does not close T24).
  - per-key-only 5/5, now with the guarded capture and the decoder pod.
  - v-capture-resources 6/8:
    - no_space refused before any pin (`capture_refused no_space`;
      capture_refused counter 1→2; slot 0, no directory);
    - total deadline cut at about 10 s (`aborted:deadline`);
    - disconnect cut about 10 s after the reader left (`aborted:write`);
    - busy and load as before (3000 sets 2936 ms without a capture vs 3488
      ms with one, capture=true in the header).
  - Failures, all three from test design, classified from logs:
    1. kill -9: the suite had no volume. `/tmp/flare` is the container's own
       filesystem, and the restarted flared logged "generated new master
       id" with 0 keys. The capture is not involved. Fixed in 975c217 with
       a PVC.
    2. Stalled reader: the 40 MB load ran in one exec past the kubectl
       wrapper's 30 s wall ("0/40000 STORED in 30004 ms"), so the guard was
       never exercised. Fixed with ≤4 MB batches.
    3. blue-green stale MATCH: the 60 s wait expired at "key counts not
       converged (61/61, 5/6 ticks)". The source was never switched, and
       the extra write re-runs the dwell before the approval is checked.
       The wait is now 180 s.
  - The guarded stalled-reader cut and the crash cleanup are therefore NOT
    yet shown in E2E.
- E2E 38198924465 (975c217, which also carries 655faa1/f5fd22b, c989c02 and
  0b8c976): **success**, 30/30 executed passes and 0 skips.
  - backup-restore 4/4. T24 did not recur, which does not close T24.
  - per-key-only 5/5.
  - v-capture-resources 7/7:
    - stalled reader: 40000/40000 STORED in batches (21.9 s). The capture
      was cut with `aborted:no_progress` about 41 s after it started, while
      the reader was still connected. That is the 30 s progress bound plus
      the time for the socket buffers to fill. The slot was released and
      the directory removed.
    - kill -9 mid-capture (PVC): serving true and 1 directory during the
      capture; after the restart, 0 directories and curr_items 49000 →
      49000.
    - no_space: `capture_refused no_space` with no pin and no directory.
    - deadline 10 s: cut after about 15 s (`aborted:deadline`).
    - disconnect: cut about 10 s after the reader left (`aborted:write`).
    - load: 3000 sets took 2152 ms without a capture and 2198 ms with one.
      This is one pod and one sample, not a capacity figure.
  - blue-green 14/14:
    - the stale MATCH is refused;
    - the attempt-bound MATCH switches the source, and AwaitingCutover is
      reached with the per-pod applied-mode gate (G1) in force;
    - cutover, retire and abort pass.
  - Not shown in E2E:
    - G1's mixed-mode hold;
    - the forwardSeen follow (f5fd22b). Both are covered by units and
      proofs only.
  - Observed, not new: in test 10 the ordinary reseed serve (not a
    capture) released its slot about 52 s after its reader left. Reseed
    serves stay without the capture bounds (residual).

## 17. Seventh round (2026-10-12, NOT reviewed)

### 17.1 Switch gate: the per-pod reader (review finding on 655faa1)

**Cause** (review, confirmed by reading and by running the old reader):

- `podReplOf` read a missing or non-numeric counter as 0 (`getD 0`) and
  called a pod settled when `forward_enqueued <= sum(outcomes)`. A reply of
  END + `cluster_replication on` + `mode duplicate` alone was therefore
  settled: Unknown read as drained.
- Running the 655faa1 reader on the counterexamples:

  | reply | old reader |
  |---|---|
  | END + on + duplicate only | settled=true |
  | `forward_enqueued abc` | settled=true |
  | outcomes 2 > enqueued 1 | settled=true |
  | enqueued 2 = `dropped_stopping` 1 + `dropped_retries` 1 | settled=false, for good |

  The last row is a pod that never drains: `forward_dropped_stopping` and
  `forward_dropped_retries` (queue_proxy_write.cc:383) were missing from the
  outcome set.
- Paths from enqueue to an outcome, read in the code:
  1. `forward_enqueued` is counted AFTER `_enqueue` returns, so a forward
     already queued but not yet counted read as drained. This is a race.
  2. handler_cluster_replication: a forward dequeued just before a shutdown
     request was dropped by `sync_unref` with NO outcome. It was neither run
     nor abandoned, because the thread clean-up only sees forwards still
     queued.
  3. Each `_run_foreign` exit counts exactly one outcome:
     - `unknown_op`;
     - when not answered: `down`, `stopping` or `retries`;
     - when answered: `applied`, `noop_*`, `missing_*` or `failed_*`.
  4. A queued forward left behind at thread clean-up is counted as
     `abandoned`.
  5. `forward_dropped_unqueued` is counted INSTEAD of `forward_enqueued`, so
     it is not an outcome of an enqueued forward.
  6. `forward_retried` and `forward_server_error_retried` count attempts.
  7. The in-cluster `handler_proxy` path, including its skip when the
     destination is a proxy, does not carry cross-cluster forwards.
  8. A process crash loses queued forwards with no outcome, and the counters
     restart at 0. Covered only by V under the write-stop premise (§17.5).

**Fix.**

- 4ceabfb (flared):
  - `cluster_replication_forward_in_flight` is +1 before queueing and −1 when
    the item is destroyed, whatever ended it. It is kept under the counters'
    mutex and sent with them from one snapshot, always, 0 included.
  - The shutdown-after-dequeue path counts `abandoned`.
- 60e86e7 (operator): `podReplParse` is strict.
  - It rejects:
    - a reply whose last line is not END;
    - a malformed line;
    - a name that appears twice;
    - a non-numeric or unknown counter;
    - a missing on/off, mode (when on) or in-flight gauge.
  - An older flared (no gauge) is unknown, so the switch is held.
  - Outcomes are enumerated.
  - settled = `in_flight == 0 && enqueued == outcomes`. Either inequality is
    a disagreement and is held, never "drained".

**Tests that fail on the old code.**

- Units: the counterexamples above plus:
  - a name appearing twice, END not last, a malformed line;
  - a gauge that is missing or non-numeric;
  - in flight > 0 with equal counters;
  - fewer outcomes than enqueued;
  - unqueued, retried or server_error_retried not counted as outcomes;
  - the gate driven by parsed replies (no switch / stays Forwarding).
  - Total: 491 checks.
- Cutter:
  - `test_in_flight_counts_a_forward_until_it_is_released` (counted while
    alive, answered or not; not counted twice);
  - `test_in_flight_and_outcomes_on_shutdown` (one forward running, one
    queued: `stopping` 1 + `abandoned` 1, gauge back to 0).
- E2E blue-green (ba2d730): every source pod's REAL stats reply goes
  through the strict reader before the switch.

**Not covered.**

- The shutdown-after-dequeue window is not reachable deterministically from
  a test, so that fix is backed by reading the code only.
- A crash still loses queued forwards (path 8).
- The gauge counts live objects. A leaked item would hold the switch for
  good. That fails closed, and it is visible in the hold message.

### 17.2 Switch window E2E made deterministic (ba2d730)

Two test seams:
- flared `FLARE_TEST_RELOAD_REPL_HOLD_FILE`: one pod keeps its replication
  mode on reload, set per pod by a file.
- operator `FLARE_TEST_MIG_WEDGE_AFTER_SWITCH_FILE`: the tick stops after
  the switch's CR patch and before its status patch.

blue-green adds these steps:

1. The approval is patched with both seams armed. The operator wedges, the
   source CR says `forward`, and the status still says Duplicating.
2. abort=true is patched and the operator pod is deleted. The new operator
   must reach Forwarding without logging "source switched to mode=forward"
   again. Abort must be REFUSED (status message) for 30 s, and the target
   StatefulSet must still exist.
3. Mixed modes: every pod applies forward except the held one, which stays
   duplicate. The status must name it for 45 s and the phase must stay
   Forwarding. The hold file is then removed; the operator's drift SIGHUP
   applies forward and the phase reaches AwaitingCutover.

The external write stop between V and AwaitingCutover remains a premise.
No write fence is implemented or installed.

### 17.3 T24: resolved addresses

- No existing log has a resolved address:
  - the failing run 38186142795 predates the resolved-IP log (0b8c976);
  - 38194519561 and 38198924465 dumped flared logs only for failing
    suites, and backup-restore passed in both.
- Checked: `(resolved ` occurs 0 times in both run logs, and nothing in
  the artifacts.
- ba2d730 makes backup-restore print, on EVERY run, pass or fail, each
  pod's `connect() … (resolved …)` failures, its `rebuild_blocked` /
  `source_size_unknown` lines and the pod IPs.
- Cause: UNDETERMINED. A further pass does not close it.

### 17.4 Capture resource protection: the package for review

- Base 13bde49; implementation 0b8c976; test fixes 975c217.
- 18 files, +691/−34, in:
  - connection_tcp (write bounds, resolved IP);
  - copy_capacity.h;
  - op_repl_snapshot (guards and bounds);
  - storage_rocksdb and op_stats (capture stats);
  - the receiver and driver scripts;
  - cutter and E2E.
- Old behaviour:
  - no reserve or space check before the checkpoint;
  - an unbounded write poll;
  - no capture stats.
- Results:
  - nix-linux 38194517215 success;
  - E2E 38194519561 13/16 (three test-design failures, record kept);
  - E2E 38198924465 30/30 (§16.5).
- Kind only. Real-environment capture is unapproved.

### 17.5 Reseed serve bounds: can the capture code be reused? (study, not implemented)

- **Write-progress bound** (`set_write_progress_timeout_ms`): reusable
  as is.
  - The reseed sender throttles itself (bwlimit), so a reading receiver
    never waits 30 s.
  - A cut ends `run_client` with a transfer failure. The receiver then
    falls back to a staged full dump (handler_reconstruction.cc ~970):
    only `busy` waits, and `no_space` stops.
  - So a cut reseed costs a dump; it does not leave the replica unseeded.
- **Total deadline:** NOT reusable as a constant.
  - A legitimate reseed takes about copy bytes / bwlimit, so a 600 s cap
    would cut large ones.
  - It would need a budget derived from size and bwlimit, with margin, and
    a retry backoff.
- **Reserve check and abort below reserve** (`decide_capture_capacity`,
  `capacity_watch_ok`): reusable. Refusal → dump fallback.
- **Not checked:**
  - the dump serve (op_dump) to a stalled peer is equally unbounded;
  - its open iterator also pins files.
- Each of these changes in-cluster reseed behaviour on a production path.
  Proposed for review, not implemented.

### 17.6 Runs

- nix-linux 38215508608 (ba2d730): **failure**.
  - 3630 tests, 1 failure, 1 omission.
  - `test_in_flight_counts_a_forward_until_it_is_released` passed.
  - `test_in_flight_and_outcomes_on_shutdown` failed: stopping 0, expected
    1, after 1.0 s.
  - Classification: test timing, inferred from the duration and the
    handler code. Against a closed port, the handler's own first `open()`
    takes about 1 s. The stop most likely came before any dequeue, leaving
    both forwards queued (abandoned at clean-up). The abandoned count was
    not printed, so this stays an inference until the rerun.
  - Fixed in df6fbb8: the test waits until the first forward is running,
    and prints every outcome count.
- E2E 38215512251 (ba2d730): **failure**.
  - cluster-replication 11/11, backup-restore 4/4, per-key-only 5/5.
  - blue-green 7/16. The cause is a product bug in 60e86e7, caught by the
    new real-stats check. flared sends stats with an EMPTY value
    (`STAT repl_follow_source `, `STAT reconstruction_last_success_source `).
    After trimming, these are two-word lines, which the strict reader
    rejected as malformed on all four source pods. In production this
    would have held the switch for good: fail closed, but never switching.
  - Test 28 then set abort while the switch had not been issued. The abort
    was correctly honored and deleted the target. Tests 29–36 failed as a
    cascade (30, 31, 32, 34 and 36 failed; 33 and 35 passed).
  - Fixed in e73d300:
    - the reader accepts an empty value (units use real empty-value
      lines; a double space is still rejected);
    - test 28 sets abort only when the source CR already says forward.
  - T24 evidence (first ever): backup-restore-nodes-1 connected to
    nodes-0's name and **resolved 10.244.0.20**, while nodes-0's pod IP was
    **10.244.0.23**. That gave three ETIMEDOUT opens; the run recovered and
    passed.
    - So the resolver DID return an address that was not the pod's
      current IP.
    - Still unknown: whether .20 was nodes-0's previous IP (not recorded
      before the deletion; e73d300 now records it), which code path made
      the connects, and why the resolver returned it.
    - The cause is still not closed.
- nix-linux 38221648313 (e73d300): **success**.
  - RocksDB build 5366 tests, legacy build 3630 tests; 0 failures and 1
    omission each.
  - Both in-flight tests passed. The shutdown test asserts stopping 1,
    abandoned 1, applied 0 and the gauge back to 0.
  - cutter prints the notify call, not its formatted values. The earlier
    "both abandoned" therefore stays an inference.
- E2E 38221651957 (e73d300): **success**, 20/20 executed passes, 0 skips.
  - backup-restore 4/4.
  - blue-green 16/16:
    - The REAL replies of all four source pods passed the strict reader
      before the switch: in_flight 0; enqueued = terminal (nodes-0 1=1,
      others 0=0).
    - The operator wedged after the CR patch: CR mode forward, status
      Duplicating.
    - abort was set and the operator pod replaced. The new operator moved
      to Forwarding ("following it to Forwarding without re-issuing it;
      abort refused from here"), with no re-issue line. Abort stayed
      refused for 30 s and the target survived.
    - Mixed modes: nodes-1 stayed duplicate while nodes-0/2/3 were
      forward. The status named it and Forwarding held for 45 s. Released,
      the phase reached AwaitingCutover. Cutover, retire, self-retire and
      abort passed.
  - Not shown: whether the follow recorded the approval as consumed. The
    test printed the wrong status field (`consumedApproval`, not
    `forwardApprovalConsumed`). The path is fixed and an assertion added
    after this run; E2E 38226570975 (ef7796b, blue-green only) passed 16/16 with it.
    That run shows `forwardApprovalConsumed` = the MATCH line after the follow.
  - T24: no recurrence (0 connect failures). Pod IPs were .10/.12 before
    the recreation and .13/.14 after. Whether .20 in 38215512251 was an old
    address is still unknown (that run did not record the earlier IPs).

## 18. Eighth round (2026-10-12, NOT reviewed)

### 18.1 In-flight gauge and one outcome per forward: every queue path

The gauge is +1 in `track_in_flight()` (before `_enqueue`) and −1 in the
`queue_proxy_write` destructor (the LAST reference). `on_post_proxy_write`
holds its own reference until it returns, after `forward_enqueued` (or
`forward_dropped_unqueued`) was counted, so the gauge cannot reach 0 before
the enqueue counter moved. The gauge and the counters are read under one
mutex (`get_crepl_snapshot`).

| path | gauge | counters | evidence |
|---|---|---|---|
| enqueue refused: no active thread, thread not running, queue full | +1 then −1 when the caller returns | `dropped_unqueued`, NOT `enqueued`, no outcome | code; gate unit (unqueued is not an outcome) |
| enqueue raced the handler's exit (`_running` read true, handler returned, `clean()` drained, THEN pushed) | **old code: stayed +1 for good** (left on a pooled thread; or run by the thread's next handler — after a destination change, a forward to the NEW destination) | old: `enqueued`, no outcome ever | **found this round**; fixed (thread `_queue_open` under the queue lock); cutter `test_enqueue_after_the_handler_returned_is_refused` with a seam in exactly that window |
| very fast queue: answered before `enqueued` is counted | ≥1 until the caller returns | one snapshot can hold outcome 1, enqueued 0 | cutter snapshot assertion in `test_in_flight_counts_a_forward_until_it_is_released`; unit: held as in flight |
| answered (applied / noop / missing / failed) | −1 when released | exactly one of the 36 answered names | cutter (classify, outcome-name set) |
| no answer: retries exhausted / destination given up / thread stopping / unknown op | −1 when released | one of dropped_{retries,down,stopping,unknown_op} | cutter (`_run_foreign`) |
| queued when the thread is cleaned or destroyed | −1 at clean-up | `dropped_abandoned` | cutter shutdown test |
| dequeued, then the shutdown check | −1 | `dropped_abandoned` (4ceabfb) | code reading only (not reproduced deterministically) |
| mode change (duplicate ↔ forward) | unchanged | unchanged: `set_mode` touches no queue; a destination change goes through `stop()` → abandoned/stopping | code (flared.cc reload) |
| exception inside a forward | — | there is no cancellation API (no pthread_cancel); the thread loop catches only `shutdown_request`, so any other exception terminates the process | = crash: queued forwards lost without an outcome; covered only by V under the write stop |
| process crash | gone with the process | gone | V under the write stop (unchanged residual) |

Answered names are now an EXACT set. The reader matched `forward_noop_*`,
`forward_missing_*`, `forward_failed_*` and `seed_*` by PREFIX, so
"unknown counter rejected" was true only outside those prefixes: a future
`forward_failed_<anything>` would have been summed as an outcome. Now:

- flared builds the name in one place (`queue_proxy_write::foreign_outcome_counter`):
  sent op ∈ {set, delete, touch} (`_get_op` sends every other post-proxy op
  as a versioned set, gat as touch) × the 13 `op::result_cast` answers →
  36 names, `forward_applied` included;
- the operator accepts exactly those 36 (classify mirrored), the five
  `forward_dropped_*` outcomes, and an exact non-terminal list
  (`forward_enqueued`, `forward_dropped_unqueued`, `forward_retried`,
  `forward_server_error_retried`, the five `seed_*` counters);
- anything else holds the switch (fail closed). A new flared counter holds
  every switch until the operator knows it — the cutter test
  `test_foreign_outcome_counters_are_the_gate_set` and a unit check pin the
  same 36-name literal, so a drift fails a build instead.

### 18.2 T24: a controlled reproduction, and convergence without pinning an address

What is established (and only this):

- 38215512251: backup-restore-nodes-1 looked up nodes-0's name and
  connected to 10.244.0.20 while nodes-0's pod IP was 10.244.0.23 (the
  earlier IPs were not recorded in that run).
- 38253608337 (7d10856), BEFORE any injection: nodes-1 looked up nodes-0's
  name and connected to **10.244.0.10 — nodes-0's IP before the
  recreation** (recorded .10 before, .13 after) — on reconstruction
  attempts 1 and 2 (two opens, two timed-out connects each), then reached
  .13 on attempt 3 by `run()`'s retry. In that run the stale answer WAS
  the previous pod address.
- Why the resolver returned the previous address (CoreDNS cache, an
  EndpointSlice still listing it, or something else) stays UNDETERMINED.

Why a single stale answer cost minutes (code, not inference):

- `connection_tcp::_open` resolves the name ONCE per open; its connect
  retries reuse that address (connection_tcp.cc `_open`).
- The staged rebuild's size probe (`probe_source_identity`) is one open
  with one connect retry. One stale answer failed the whole probe.
- The staged rebuild then PARKED as `source_size_unknown`, which only the
  operator's `rebuild_resume` ends, at most once per 5 min per node.
- Every other failed step already retried by itself (`run()`: 2, 4, 8, 16,
  30 s; a fresh connection, so a fresh lookup, every attempt).

Reproduction (backup-restore test 5, kind only, deterministic):

- A stop point right before the size probe
  (`FLARE_TEST_STAGED_PROBE_HOLD_FILE`, file on the PVC), so the attempt's
  own WAL-sync lookups have already reached the current master.
- While held, the replica's resolver is given a stale answer for the
  master's name (`/etc/hosts`, first in nsswitch): 192.0.2.10 (TEST-NET-1,
  never a pod IP), dropped on the kind node (`iptables -t raw … DROP`), so
  a connect times out as in T24. Released; once the probe has connected to
  it (its own log line `(resolved 192.0.2.10)`), the entry is removed and
  the next attempt held again. Repeated for 40 s.
- Required: the replica rebuilt from the CURRENT master (`staging copy …
  verified: lineage …, history …` and `staged rebuild DONE`), Ready, every
  key readable, within 120 s after the stale answers end.
- On the old probe: FAIL, E2E 38257119887 (a2afc1f): parked twice, not
  rebuilt within 120 s (§18.5).

The fix (commit after the old-code run):

- The probe makes a fresh connection — so a fresh lookup of the same NAME —
  when it got no complete reply: up to 3 tries, 1 s then 2 s apart
  (shutdown ends the wait). Never an address cached or pinned; the source
  is still chosen by the map, and what it answers is checked as before.
- A source that did not answer the size probe fails the attempt (retried
  by `run()`); it no longer parks. A source that ANSWERED without its size
  still parks (that needs a human or a resume, as before).
- The copy-gate probe right before the switch gets the same retries, so
  one stale answer no longer abandons a whole verified staging copy.
- Cutter: a source that listens only after the first try fails is reached
  on a later try; a source that never answers ends Unknown and NOT
  answered within 10 s.
- Residual: if a lookup stays stale for the whole retry ladder, `run()`
  gives up after its 60 attempts (~30 min) exactly as for any unreachable
  source; and the cause of the stale answer is not addressed.

### 18.3 Reseed and dump serve bounds (implemented this round, NOT reviewed)

| | before | now |
|---|---|---|
| reseed serve (`repl_snapshot` without `capture`) to a peer that stays connected and stops reading | blocks in write for as long as the connection lives; checkpoint hard links, the file-deletion pin and the one-serve slot (every other reseed: busy) held | a write with no progress for 120 s ends the serve; checkpoint removed, deletions re-enabled, slot freed |
| `dump` serve, same peer | holds the iterator (on RocksDB a snapshot pinning files) | same 120 s progress bound; iterator released |
| a slow but reading receiver (bwlimit) | completes | completes: NO total deadline (cutter: runs past several windows) |

Why 120 s: both receivers read while they write, so only a receiver that
stopped (hung, a disk stalled for minutes, a half-open connection) waits
that long; a receiver's own space watch ends a copy by closing the
connection. The sender's bwlimit sleeps are between writes and do not count.

Receiver after a cut (code, unchanged): snapshot → "the snapshot transfer
failed" → staging removed, live copy unchanged → staged full dump; busy →
retried later, no dump; a dump without END is never accepted (staged:
abandoned; merging: the PARTIAL marker stays and `run()` retries).

Residuals: deletions re-enabled is not asserted directly (no getter; same
cleanup lines as the slot release, which is); a receiver that reads slowly
forever is not bounded (by design); a human or tool `dump` whose reader
pauses over 120 s is now cut; checkpoint creation, the CRC pre-read and a
long dump's iterator memory are not bounded; a partition dump that skips
keys for a long time is bounded only through its writes. The old code's
failure of the two stop-reading tests is by reasoning (they cannot compile
against it: the window is a new static); it was not run.

### 18.4 Review units (what is done, by diff)

1. **Capture resource protection** — 13bde49 → 0b8c976 + 975c217 (18 files,
   +691/−34). nix-linux 38194517215; E2E 38194519561 (13/16, test design),
   38198924465 30/30. §17.4.
2. **Migration switch gate (operator)** — 655faa1, f5fd22b (applied state,
   follow-not-abort), 60e86e7 + e73d300 (strict reader), 9eb11ee (exact
   counter set). Units 494; E2E 38221651957, 38226570975.
3. **In-flight accounting (flared)** — 4ceabfb, df6fbb8, 9eb11ee (outcome
   names in one place), 6f89f2d (enqueue after the handler returned).
   §18.1 lists every path.
4. **Deterministic switch-window E2E** — ba2d730, ef7796b (seams
   FLARE_TEST_RELOAD_REPL_HOLD_FILE, FLARE_TEST_MIG_WEDGE_AFTER_SWITCH_FILE).
5. **T24 probe** (this round) and 6. **serve bounds** (this round): §18.2,
   §18.3.

Not implemented: the write fence (the external write stop stays a
precondition), RBAC/HMAC on the approval, repair R, A/B, X4, the capture
partition filter, the cause of T24's stale answer.

Waiting for the user (not approved here): the snapshot / migration method
(A/B/X4), the approval measures, a real-environment capture and capacity
evaluation, environments, old-backup compatibility.

### 18.5 Runs (kind / nix only, NOT reviewed)

- nix-linux 38248809605 (9eb11ee, the race test WITHOUT the fix): **failure**,
  as expected, in both builds (legacy 3632 tests, 2 failures).
  - `test_enqueue_after_the_handler_returned_is_refused`: `r=0 queued=1` —
    the forward was pushed onto the thread after its handler returned and
    clean-up drained it (the old-code evidence).
  - `test_foreign_server_error_is_counted` (the NEXT test): dropped 2,
    expected 1. Not predicted. Inferred: the orphaned forward was abandoned
    (one drop counted) when its thread was destroyed, after the next test's
    setup. Consistent with: it passed once the fix was in (next item). Not
    proven otherwise.
  - `test_foreign_outcome_counters_are_the_gate_set` passed.
- nix-linux 38250385227 (6f89f2d, race fix + serve bounds): **success**.
  Legacy 3633, RocksDB 5371; 0 failures, 1 omission each. The race test,
  the three serve-bound tests and `test_foreign_server_error_is_counted`
  passed.
- E2E 38250389416 (6f89f2d, backup-restore only): **failure**. Tests 1-4
  passed; test 5 failed its PRECONDITION: a second restore after the
  history moved on → "partition 0 has NO master … unfit … waiting for the
  ex-master" (operator log), no staged rebuild reached the probe. A test
  design error; nothing about the probe is shown. Fixed in 7d10856 (the
  reproduction runs inside the first restore).
- E2E 38253608337 (7d10856, old probe): **success, but NOT evidence for
  the old probe.** Cycle 1 used the stale address (failed open, PARKED
  source_size_unknown, the operator resumed it at once: "a slot is free").
  Cycle 2 did not: the test counted the per-connect lines, and cycle 1's
  closing line, logged late, passed for cycle 2's use; the stale entry was
  removed at once and the second probe resolved the real address. Rebuilt
  10 s after the stale window, 1 park. A test bug; fixed in a2afc1f (a
  cycle counts only a failed OPEN). The run also gave the natural
  stale-answer evidence in §18.2.
- E2E 38257119887 (a2afc1f, old probe): **failure, the old-code evidence**.
  Tests 1-3 passed. Test 4: two stale cycles, each probe's open to
  192.0.2.10 failed (2 failed opens) and each PARKED the rebuild
  (`source_size_unknown`); the operator resumed the first at once, the
  second stayed parked; not rebuilt or Ready within 120 s after the stale
  window ended (timeout at 123 s). As predicted.
- nix-linux 38262348303 (76ed011, the probe fix): **success**. Legacy 3635,
  RocksDB 5373; 0 failures, 1 omission each; both probe tests passed.
- E2E 38262353210 (76ed011, backup-restore + blue-green-migration):
  **success**, 20/20 executed passes, 0 skips.
  - backup-restore 4/4. Test 4: one stale cycle; the probe's first try
    failed against 192.0.2.10, it "answered the identity/size probe on
    attempt 3 (a fresh lookup each time)"; 0 parks; the staging copy
    verified (lineage, history 4:…), "staged rebuild DONE", Ready when the
    stale window ended, every key read back. No natural stale answer this
    run.
  - blue-green 16/16 (strict reader with the exact counter set on real
    replies; wedge + replacement + abort refused; mixed modes held).

## 19. Ninth round (2026-10-13, NOT reviewed): the approved first-move scope

The user approved the METHOD for the first cross-cluster move, for
development and verification only (2026-10-13). Not approved: real
environments, pf-dev, real data, paid environments, real capture, the web
switch, destructive steps, the RBAC/HMAC measures.

### 19.1 Review 2026-10-13 [P1]/[P2]

- **[P1] cause**: `_queue_open` did not tell handler generations apart.
  `cluster_replication::_enqueue` copies the active map, leaves the lock,
  then enqueues; a thread reused for another handler in between had its
  queue open again, so an old forward reached the new handler.
  **Fix 94f7d39**: `enqueue(q, max, expected_id)` refuses unless the queue
  is open AND was opened by the run with the id the caller found (both
  under the queue lock); `_running` is no longer read unlocked there.
  **Test that fails on the old code**:
  `test_post_proxy_forward_is_not_handed_to_a_reused_thread` (48771da: the
  hook reuses the very thread for a handler to another port between the copy
  and the enqueue; asserts enqueued 0, unqueued 1, nothing queued, in-flight
  0, no outcome).
- **[P2] cause**: the dump reset its progress bound before sending END /
  SERVER_ERROR, so a receiver that stopped reading after the data held the
  final frame unbounded. **Fix 94f7d39**: the bound stays on through the
  final frame; a guard restores it (and nodelay) on every return.
  **Test that fails on the old code**:
  `test_final_frame_is_bounded_when_only_it_is_stuck` (data flows, only the
  final frame is stuck; must end with errno −4 within the window, bound 0
  after return, iterator released); `test_bound_is_off_after_a_complete_dump`
  for the normal path.
- Runs: §19.8. Old code (48771da, nix-linux 38277313979): both fail in
  both builds — P1 `enqueued=1 unqueued=0 queued=1 in_flight=1`; P2's
  notification "not ended by itself after 10023 ms", but its FIRST failing
  assertion was the test's own precondition (peer read 48204 < 51200: the
  hook stopped the peer with bytes still buffered — a test defect, fixed in
  66d0fd7: the peer drains first and the test asserts the hook was reached).
  The fixed P2 test was not re-run on the old code. Fixed code (05eee82,
  nix-linux 38279206031): P1 `enqueued=0 unqueued=1 queued=0 in_flight=0`;
  P2 "hook reached=1, ended by itself=1 after 2055 ms, errno -4, peer read
  52490 bytes, bound after return 0".
- Residuals: the same capture-then-enqueue shape exists in cluster.cc's
  in-cluster proxy paths (`_get_proxy_thread`, `_enqueue`) — NOT changed
  (open finding). The dump bound also ends a human `dump` whose reader
  pauses > 120 s.

### 19.2 Full matrix on 9260841 (code = 76ed011): 38267434934

14 E2E jobs. 11 succeeded. Summary lines: 322 tests, 3 failures, 22 skips
(continuous-replication 17 = the gated outage suites, wal-recovery 3,
failover-data 1, authority 1) → 297 executed passes. Not a candidate run
(no candidate was set); NOT green:
- **cross-cluster 4, 5** (faults: snapshot-push destination restart → "NO
  master … unfit"): known **X4**, excluded from green, unchanged.
- **empty-source 8** (activation boundary, UNKNOWN): failed on its
  precondition "no connect attempt ended by the connect deadline". Cause,
  from the code and the run: 0b8c976 changed the connect-failure line from
  `connect() failed: …` to `connect() to <host>:<port> (resolved <ip>)
  failed: …`; the test still matched the old text. The behaviour it guards
  held in the same run (31 Unknown deferrals, dumps 1→1, no truncate,
  activated after unblocking, items 400 = 400). Fixed in c48ccd9 (matches
  the new format and the master's own address). Classified as a test defect
  on that evidence; the fixed matcher passed in 38279220151 (9/9).

### 19.3 Item 1: per-key-only seed, push path closed by configuration

Before: the switch (`snapshotPush: false` → `cluster-replication-snapshot-push
= false`) was honoured only by the SOURCE's seed. The destination's
`repl_snapshot_push` server checked only partition count and freshness, so a
fresh destination took a push from any other source left at the default or
from a hand-sent command; a FlareMigration target was provisioned without
any replication block.

- 1a9f013 (tests, check disabled) / **be8831d (fix)**: with the switch off a
  node refuses every incoming push FIRST (`SERVER_ERROR
  snapshot_push_disabled`), before routing, relay and freshness. Set by
  flared at start and on reload; new stat `snapshot_push_accept on|off`
  (shown whether or not the node replicates). Cutter:
  `test_switch_off_refuses_an_incoming_push_before_anything_else` (fails on
  1a9f013), `test_switch_on_does_not_refuse_by_the_switch`. E2E
  cluster-replication-per-key-only 6: the destination CR
  `{enabled: false, snapshotPush: false}`, a hand-sent push is refused,
  data and history unchanged (old code: `not_fresh`).
- **be60dbb (found by the first E2E run)**: with `enabled: false` the
  operator rendered only `cluster-replication = false` and DROPPED the
  switch, so a destination's `snapshotPush: false` never reached flared
  (38279209918 on 05eee82: per-key-only 6 "snapshot_push_accept on" after the
  patch) and the FlareMigration target's provisioned switch would have been
  overwritten by its own operator. ee13ef8's unit test had compared the seed
  against the `some` renderer, which the operator does not use for a
  disabled block. Now the replication-off rendering (rocksdb-only reconcile,
  clear, the migration seed) carries the switch when false and writes the
  file even with no rocksdb tuning; the default is unchanged byte for byte.
  flare_unit 499. Because of this, the E2E never observed the old flared
  ACCEPTING the push (the operator bug failed the test first); the old-code
  evidence for the flared check is the cutter test on 05eee82.
- **ee13ef8**: a FlareMigration whose source has `snapshotPush: false`
  provisions the target with the same block (CR and first extra.conf equal
  to what the target operator renders). flare_unit 498 (+4). No E2E of a
  per-key-only FlareMigration yet.
- A/B and X4 stay open and untouched; the move does not use them.

### 19.4 Item 2: the explicit write stop

docs/RUNBOOK.md#initial-migration (7974102): every writer (clients,
people/tools, flush_all, reaper, lazy expiry, forwarder, restore/rebuild
operations, destination), how each is stopped and confirmed, positions as
corroboration only, resume conditions, abort/rollback before the switch,
held in Forwarding, after the switch (no way back), after cutover. Not the
automatic fence (not implemented). New gap found while writing it:
**W1** — expiry writes (reaper: no CR switch; lazy expiry on reads: cannot
be stopped while reads continue) move the source position, so the gate
holds; a CR switch for the reaper or "accept repeated V" is a decision.

### 19.5 Items 3-4: hybrid after the move, and the fixed acceptance

Hybrid = `replIdentityForward` + `replFollowEnabled` (+
`readUnavailableError`); chart examples now set them (chart defaults
unchanged); RUNBOOK#post-migration-hybrid.

Acceptance (fixed by the user) against existing tests (all
continuous-replication, ContinuousReplication.lean; last passing full run
38267434934 on 9260841):

| Element | Existing coverage | Missing before this round |
|---------|-------------------|---------------------------|
| both paths cut (forward + repl_sync_wal) | "cut …" (:321), "repeated cuts" (:817), "replica crash …" (:989): REJECT both directions on the flare port | — |
| create / update / delete during the cut | "cut …" 10/5/5; "repeated cuts" per cycle | — |
| writes stop, resume from the APPLIED cursor | "heal …" (:371): applied ≥ master head at the cut, not backwards | a stop the run itself checks (head unchanged after the stop) |
| no rebuild | `reconstruction_started` unchanged ("heal", "repeated cuts") | `rocksdb_wal_fallback_to_dump` in the same run (only the crash test, which restarts the process) |
| no Pod recreation / restart | UID unchanged | `restartCount` of replica AND master |
| same master / history | implicit | master pod, `rocksdb_source_epoch`, `rocksdb_master_id` asserted unchanged |
| contents match | `curr_items`, 5 updated values, 10 created keys, 2 deletes sampled | every key incl. absent deletes, on master and replica |
| lagging read: master reachable → proxy | "local read guard" (:609): selective cut, value from the master, cursor not advanced | in the same run as the rest |
| lagging read: master unreachable → explicit error | "read-unavailable-error" (:742): one direction cut | with both paths cut and the replica lagging, in the same run |

New: **b5b218a** "ACCEPTANCE: …" does all rows in one run (phase 1
selective cut with reads reachable, phase 2 full cut, both with
create/update/delete). **Passed** in 38279230679 (05eee82,
continuous-replication 17/17): phase 1 (applied 158 < head 171) replica
reads = the master's values (p1_0, p1_4, new_0) and a miss for the deleted
acc_10; phase 2 = `SERVER_ERROR read unavailable` (4 s) for acc_5 and acc_0;
writes stopped at head 183 (unchanged after the heal); applied 158 → 183,
following; reconstruction_started 2→2, wal_fallback_to_dump 1→1 (the 1 is
from test 7's flush_all rebuild), restartCount 0→0 on both, both UIDs, the
master pod, epoch and master id unchanged; 28 keys (6 deleted) equal on
master and replica. Limits of this evidence: the operator's map showed the
replica at balance 0 during phase 1 (withheld), so the run shows the
client-visible property, not which layer (operator withholding or the
replica's own guard) produced it — the guard alone is the "local read
guard" test; one run, kind. Unit coverage (cutter):
`test_follow_local_read_guard_until_caught_up`,
`test_local_read_guard_disconnect_lag_and_recovery`,
`test_stale_balance_read_guard_uses_production_routing_and_recovers`,
`test_follow_disconnect_is_not_a_rebuild`,
`test_follow_only_unsatisfiable_positions_rebuild`.

Recorded separately as rebuild cases: WAL retention exceeded
(continuous-replication-purge T6; outage phase B, gated), failover to a new
master ("planned promotion" :1069), copy loss (no dedicated in-cluster test;
RUNBOOK restore sections). Evidence class: kind iptables cut = network
partition evidence; NO real-AZ test exists or is approved.

### 19.6 Item 5: loss

Asynchronous replication: losing a master that holds writes not yet on a
replica loses them; zero loss is not guaranteed and WAL-only streaming
would not change it. The last-resort promotion after
`FLARE_FOLLOW_FAILOVER_WAIT_SECONDS` is lossy ("PROMOTION NOT LOSS-FREE …
LAST RESORT"). Written into RUNBOOK#post-migration-hybrid and the chart
example comment.

### 19.7 What is left (finite)

Implementation (C):
1. cluster.cc capture-then-enqueue (P1 shape in the in-cluster proxy) —
   open finding, not changed.
2. E2E of a per-key-only FlareMigration (ee13ef8 is unit-tested only).
3. W1 reaper switch in the CR — only if the user chooses it.

Verification (C, CI):
4. done: old-code runs 48771da (P1/P2) and 05eee82 (push refusal, cutter);
   fixes in CI (05eee82). Open: the fixed P2 test was not re-run on old code.
5. done: b5b218a acceptance and c48ccd9 empty-source 8 passed (05eee82);
   per-key-only 6 passed after the operator fix be60dbb (38285744476).
6. the full matrix + nix-linux on ONE pinned candidate (X4 excluded from
   green, skips listed, not passes).

Operational decisions (U):
7. writer inventory and owners for the stop; W1 choice.
8. approval separation: §16.4 proposal — RBAC split (a verifier role that
   alone may patch FlareMigration; GitOps `ignoreDifferences` or merge =
   approval) + audit log; HMAC over the approval line (key in a Secret
   readable only by the verifier and the operator) only if the RBAC split
   cannot be guaranteed. Needed decisions: who approves, whether the
   cluster's RBAC/GitOps can hold the split, key custody/rotation if HMAC.
   Nothing implemented.
9. production settings (values for hybrid, readUnavailableError, reserve,
   WAL retention sized to the longest cut to survive), R6 latency numbers.
10. capacity/performance measurement (tmpfs headroom, WAL retention under a
   cut, concurrent rebuild) — needs an approved environment.
11. the unexplained read failures: R1 (cluster-init 29 / authority 29
   cause), R4 (map change under blocked delivery), 2 unattributed DURING
   warnings, T24's stale address cause.
12. restore / rollback / monitoring rehearsal (R8), old-backup
   compatibility, real capture, environments, A/B/X4 — all awaiting the
   user.

### 19.8 Runs (kind / nix only, NOT reviewed, no candidate yet)

- nix-linux 38277313979 (48771da, P1/P2 tests WITHOUT the fixes):
  **failure as predicted** — legacy 3638 / RocksDB 5376 tests, 2 failures
  each (the P1 and P2 tests; P2 on its precondition first, see §19.1).
- 05eee82 (P1/P2 fixes + fixed P2 test + acceptance + empty-source matcher;
  the destination refusal TEMPORARILY disabled, A3):
  - nix-linux 38279206031: **failure as predicted** — legacy 3640 /
    RocksDB 5378, 1 failure each:
    `test_switch_off_refuses_an_incoming_push_before_anything_else` (got
    `SERVER_ERROR not_compiled` / not refused); P1/P2 tests passed.
  - E2E 38279209918 per-key-only: 1-5 pass, **6 failed, NOT as predicted**:
    the switch never reached the destination (operator defect → be60dbb).
  - E2E 38279220151 empty-source: **9/9** (8 counted 125 connect-deadline
    lines to the master's address).
  - E2E 38279230679 continuous-replication: **17/17** incl. ACCEPTANCE.
- be60dbb (refusal restored f373d68 + operator rendering fix): nix-linux
  38285740092 **success** (legacy 3640 / RocksDB 5378, 0 failures, 1
  omission each); E2E 38285744476 per-key-only **6/6** — 6: the hand-sent
  push answered `SERVER_ERROR snapshot_push_disabled`, destination master
  id / copy id / epoch and items unchanged.
- **Candidate pinned: be60dbb** (label `saf10-first-move-c1`; later commits
  docs only). Final full matrix + nix-linux on it: next. X4 (cluster-
  replication-faults 4-5) is excluded from green; skips are listed, not
  counted as passes.

## UNKNOWN

- whether a blocking connect to a black-holed LB address reaches the
  fail-fast path (kernel ETIMEDOUT) or holds a thread;
- what a delete of a missing key returns behind an LB;
- whether the operator's enable → Dumping path waits for anything on the
  destination.
