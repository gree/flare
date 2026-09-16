# Design: continuous WAL replication (RocksDB, intra-cluster master → replica)

Status: **DRAFT for review — audit and design only, no implementation.**
Scope owner: SAF-10. Supersedes nothing; see §0.3 for how this relates to
[design-wal-cluster-replication.md](design-wal-cluster-replication.md), which
is a different (cross-cluster, parked) design.

---

## 0. What this is for

### 0.1 The requirement

While the master and its data survive, a temporary loss of connectivity to a
replica must not leave that replica permanently behind: after the link
returns, the replica must catch up **automatically and without gaps**. This
must hold during normal operation, not only during initial build, and must
survive disconnection and process restart on either side — the goal is not
"stay connected" but "resume from the applied position".

### 0.2 Scope of this design

In scope:

* RocksDB ↔ RocksDB, **same cluster**, master → replica of the **same
  partition**.
* **Asynchronous** replication.
* Incremental recovery while the needed WAL is retained; automatic
  snapshot + WAL rebuild when it is not.

Explicitly **not** guaranteed by this design, and not to be claimed anywhere
as a consequence of it:

1. **No durability guarantee for acknowledged writes against master data
   loss.** Replication is asynchronous; a write the client was told was
   stored can be lost if the master's data is destroyed before the replica
   fetched it. Closing that requires synchronous acknowledgement (§8, out of
   scope).
2. **No synchronous ACK**, therefore no bounded staleness at the moment of
   acknowledgement.
3. **No support for a different partition assignment** between master and
   replica (WAL batches apply verbatim — §1.1).
4. **No Tokyo Cabinet support.** The WAL mechanism is RocksDB-specific; a
   `tch` node keeps today's behaviour.
5. **Not distributed writer fencing.** Source/generation checks here reduce
   the window in which a deposed master's stream is applied; they do not
   establish single-writer exclusion (that is H6 / EV-01, unchanged).

### 0.3 Relation to the existing WAL design document

`design-wal-cluster-replication.md` designs **cross-cluster** WAL transport
for same-topology migration, is parked as DRAFT, and its verdict is "do not
start". This document is a different problem — intra-cluster, same partition,
continuous — and reuses its established background facts (§2 there) but none
of its migration-specific machinery. The two must not be conflated in the
register: that document is referenced from SC-13's "future design" wording;
this one proposes the concrete controls.

---

## 1. Audit of the current implementation

Everything below was read at commit `da840c0` on branch
`safety/saf-10-wal-replication`. Line numbers are from that revision; symbols
are given so they survive line drift.

### 1.1 WAL mechanism, LSN, and what an entry is

| Fact | Where |
|---|---|
| Replication uses **RocksDB's own WAL**, not a flare-maintained log: `GetUpdatesSince` through a `TransactionLogIterator` | `storage_rocksdb::get_updates_since`, src/lib/storage_rocksdb.cc:1624 |
| The LSN is the **RocksDB sequence number of the whole DB on that node** — not per partition, not per key | `storage_rocksdb::get_latest_sequence_number`, src/lib/storage_rocksdb.cc:1617 |
| A stream unit is a `WriteBatch` plus its sequence, applied **verbatim**: no per-key re-hash, no partition filter, no version comparison | `storage_rocksdb::apply_batch_with_lsn`, src/lib/storage_rocksdb.cc:1743 |
| Consequence: a WAL stream reproduces the source node's key set byte for byte, **including** keys that do not hash to this partition (orphans) and including reserved replication keys | same |
| Every local storage write on the master is in its WAL — including reaper deletes, orphan purge, expiry-driven deletes and truncate | implied by RocksDB; `storage.h:237-239` documents that storage-level removes are local-only at the *op* level |

`get_updates_since` reads **the entire iterator into a
`vector<pair<uint64_t, WriteBatch>>`** before anything is sent
(storage_rocksdb.cc:1640-1648). Memory is therefore proportional to the
receiver's backlog — a resource hazard for a far-behind replica (§2.7).

### 1.2 Applied position (cursor) and crash consistency

* The cursor lives **inside the same RocksDB** under a reserved key
  (`kReplLastLsnKey`). Read: `get_repl_last_lsn` (storage_rocksdb.cc:1783).
* `apply_batch_with_lsn` copies the incoming batch, **appends the cursor Put
  to the same batch**, and issues one `Write()`. RocksDB applies the merged
  batch atomically, so **data and cursor cannot disagree after a crash**
  (storage_rocksdb.cc:1743-1760). Safety condition §2.2 is therefore already
  satisfied *on this path* and must not be regressed.
* Because the cursor Put is appended last, it wins over any cursor Put that
  travelled inside the master's own batch. Correct — but note that **other
  reserved keys are not neutralised**: a `kReplMasterIdKey` Put in the
  master's WAL is replayed onto the replica, silently changing its lineage
  token (§2.6 hazard).
* `set_repl_last_lsn` (storage_rocksdb.cc:1798) is a *separate* durable Put
  used only for seeding after a full dump — not crash-atomic with the data it
  claims to describe (§1.7).
* Durability is governed by `rocksdb-sync-writes` (`_sync_writes`,
  storage_rocksdb.h:109), default **false**: writes survive a process crash
  (they are in the OS page cache and RocksDB's own WAL) but a host/power loss
  can lose the most recent writes on both master and replica.

### 1.3 Lineage and generation

* `master_id` is a **per-DB UUID** under `kReplMasterIdKey`:
  `_load_or_generate_master_id` (storage_rocksdb.cc:215), `set_master_id`
  (262, `wo.sync = true`), `regenerate_master_id` (287).
* `regenerate_master_id` is called at **promotion when the replication cursor
  is ahead of the node's own sequence**, deliberately breaking lineage so two
  incomparable sequence spaces can never be compared.
* Server-side gate: a client whose `master_id` differs is refused with
  `master_id_mismatch` (op_repl_sync_wal.cc:145-155); a client whose LSN is
  beyond the master's latest is refused with `lsn_ahead` (157-170).
* Client-side gate: WAL catch-up is attempted **only** when
  `repl_last_lsn > 0 && local master_id == peer master_id`
  (`handler_reconstruction::_try_wal_reconstruction`,
  src/lib/handler_reconstruction.cc:498-513).
* After a full dump the replica **adopts the peer's `master_id`**
  (handler_reconstruction.cc:~330).

**Consequence for continuous replication (important, and a real cost):**
`master_id` identifies a *DB*, and the sequence space belongs to that DB.
After a failover the new master's own sequence space is unrelated to the one
the surviving replicas were following, so surviving replicas **cannot resume**
against the new master — they must rebuild (snapshot + WAL). This design
accepts that and makes it automatic and bounded; it does not pretend
otherwise. A per-source cursor scheme that avoids the rebuild is out of scope
(§8).

### 1.4 Retention and "history is gone"

* `_wal_ttl_seconds` (default 86400) and `_wal_size_limit_mb` (default 10240)
  are constructor parameters (storage_rocksdb.h:107-108, 221-223) plumbed
  from config and hot-reloadable.
* Purged history is detected precisely: `GetUpdatesSince` returning `NotFound`
  → `ERR_LSN_PURGED` (storage_rocksdb.cc:1631-1636) → server answers
  `lsn_purged` (op_repl_sync_wal.cc:172-177) → client classifies it
  (`client_lsn_purged`) and the caller falls back to a rebuild.
  **This is already fail-closed: a purged history is never reported as
  "synchronised".**

### 1.5 Transport: what exists today

`repl_sync_wal <lsn> <master_id>` — one request, one response:

* Server (`op_repl_sync_wal::_run_server`, op_repl_sync_wal.cc:129-287):
  lineage check → slave-ahead check → `get_updates_since` → for each batch:
  structural validation of the batch at read time
  (`storage_rocksdb::validate_batch_rep`), batch-size ceiling
  (`batch_too_large`), `LSN <seq>` line, `BATCH <size> <crc32>` line, raw
  bytes, optional bandwidth/interval throttle → `END`.
* Client (`_parse_text_client_parameters`, 296-470): reads each batch with
  `readsize()` (a short-read bug here was the source of "unknown WriteBatch
  tag" corruption), **verifies CRC before applying**, then
  `apply_batch_with_lsn`. Any error aborts with nothing written for that
  batch.
* **There is no follow/tail mode.** The server streams what exists at request
  time and sends `END`; it never waits for new writes. Continuous replication
  does not exist today — this is the hole this design fills.

### 1.6 Reconstruction lifecycle (the only consumer today)

`handler_reconstruction::run` (src/lib/handler_reconstruction.cc:76):

1. One handler = one reconstruction id (`stats_object->reconstruction_begin()`),
   in-handler retry with backoff 2,4,8,16,30,30…, up to 60 attempts;
   `reconstruction_succeeded_from(id, source)` /
   `reconstruction_failed_final(id)` / `reconstruction_aborted_by_shutdown(id)`.
2. `_run_once` (130): corruption self-heal → connect → try WAL
   (`_try_wal_reconstruction`) → else snapshot bootstrap
   (`op_repl_snapshot`, only if the peer supports it) → else truncate + full
   dump (`op_dump`), with a "source is not newer than local data" guard →
   adopt `master_id` → seed cursor → activate with retry.
3. **On success the handler exits. Nothing keeps pulling WAL afterwards.**
   Live replication after activation is op-level proxy only (§1.8).
4. **Any** WAL failure — including a mid-stream disconnection — logs
   "falling back to full dump" and proceeds to snapshot/dump
   (`_try_wal_reconstruction` tail, handler_reconstruction.cc:540-556). The
   already-applied batches keep their cursor, so resuming *would* be possible;
   the code does not attempt it.

### 1.7 Initial copy → continuous hand-off (where the gap is today)

* **Snapshot path is gap-free.** `create_snapshot_checkpoint(out_path,
  out_seq)` (storage_rocksdb.cc:1037) captures the exact sequence the
  checkpoint contains; `swap_in_snapshot(staging, checkpoint_seq)` (1129)
  verifies the staged checkpoint read-only, swaps under the whole-lock,
  reopens, **seeds `repl_last_lsn = checkpoint_seq`**, rescans `curr_items`
  exactly and clears the corruption latch. Everything after `out_seq` is in
  the master's WAL, so a WAL sync from there is exactly continuous.
* **Full-dump path is not.** `_seed_repl_lsn_after_dump`
  (handler_reconstruction.cc:568) seeds the cursor with `peer_latest_lsn`
  **probed before the dump started**. The dump is a non-atomic logical scan
  that may run for minutes. Replaying the master's WAL from a pre-dump LSN
  re-applies batches the dump may already have included. For a quiescent
  replica this is merely redundant; for a replica that is **also receiving
  live writes** it is a stale-overwrite hazard (§2.6). It is harmless today
  only because nothing replays WAL after activation.

### 1.8 Live write path, and who receives it

* The master forwards each write to the partition's **Active** slaves only:
  `cluster::post_proxy_write` (src/lib/cluster.cc:1570) iterates
  `p_tmp.slave`, and `_reconstruct_node_partition` (cluster.cc:2146+) puts a
  slave into `npm[partition].slave` only when `node_state == state_active`;
  Prepare/Ready slaves go to the separate *prepare* map. **A Prepare replica
  receives no live proxied writes** — reconstruction therefore runs without a
  concurrent live writer, and activation is the moment the write path opens.
* `queue_proxy_write::run` (src/lib/queue_proxy_write.cc) retries
  `max_retry` times, then logs and counts
  `proxy_write_dropped[<dest>]` — **the client was already told STORED**.
  There is **no per-write acknowledgement** from replica to master.
* `incr`/`decr` are forwarded as **operations** and are therefore
  order-sensitive and non-idempotent at the op level; deletes are forwarded
  with a version (the reaper uses `post_proxy_write` for exactly this
  reason), while `orphan_purge` is local only — i.e. today's op-level path
  has several divergence sources that a verbatim WAL stream does not have.

### 1.9 What the operator can observe today

From `stats` (src/lib/op_stats.cc:169-240): `reconstruction_started /
completed / failed`, the completion **record**
(`reconstruction_boot_id`, `_current_id`, `_current_state`,
`_last_success_id`, `_last_success_source`), `rocksdb_master_id`,
`rocksdb_repl_last_lsn`, `rocksdb_latest_sequence_number`, the WAL error
counters (`_lsn_purged`, `_lsn_ahead`, `_master_id_mismatch`,
`_apply_failure`, `_crc_mismatch`, `_other_error`, `_fallback_to_dump`),
`rocksdb_snapshot_bootstrap`, `rocksdb_corrupted`,
`rocksdb_resync_failure_count`, `proxy_write_dropped[dest]`.

Missing for a continuous stream: **which peer** is being followed, the
**state** of the stream, the master position **with the time it was
observed**, the time of **last progress**, and a **reason code** for the last
reconnect/rebuild. §4 defines these.

---

## 2. Replication path: the decision to review

### 2.1 Option A (proposed) — WAL is the only apply path for a WAL-mode replica

The master stops proxying writes to replicas that are in WAL mode; every
change reaches them as WAL batches, in master commit order, applied verbatim
and atomically with the cursor.

Why this is the first candidate:

* **Ordering is the master's commit order by construction.** No interleaving
  of two channels, so no order inversion, no delete-then-set resurrection, no
  double application of non-idempotent ops.
* It **removes existing divergence sources**: expiry/reaper deletes, orphan
  purge and truncate are ordinary local writes on the master and therefore
  replicate automatically, instead of needing (and sometimes lacking)
  explicit op-level replication.
* Recovery after a blip is the same mechanism as normal operation — the
  property we are asked to guarantee is the *only* mode, not an exceptional
  one.
* The existing atomic apply (`apply_batch_with_lsn`) and CRC/validation are
  reused unchanged.

Costs and risks, stated plainly:

* **Replica reads become lag-bounded rather than write-synchronous.** Read
  eligibility must be defined on measured lag (§4.3); the safe default for the
  first stage is to keep WAL-mode replicas out of the read set.
* **`proxy_write_dropped` stops being the divergence signal** for WAL-mode
  replicas. The replica-repair ledger (SAF-02/05) must not fire on them (§4.4)
  — its input disappears by design, replaced by stream-state feedback.
* **Failover forces a rebuild** of the surviving replicas (§1.3).
* A master that cannot serve WAL (purged history) turns a blip into a
  rebuild; retention sizing becomes an operational parameter with teeth.

### 2.2 Option B — keep op-level proxy and add a WAL catch-up

Rejected as the primary path, and if it is chosen it must carry its own
evidence, because two channels writing the same keys require proof of:

* ordering between a live proxied write and a WAL batch that contains an
  older value for the same key (the §1.7 seeding hazard made permanent);
* deletes: a replayed old `set` after a newer delete resurrects a key;
* non-idempotent ops (`incr`/`decr`) applied once as an op and once inside a
  batch.

None of these can be settled by the version field alone: the WAL apply path
does **not** compare versions (§1.1) — it overwrites.

### 2.3 What "WAL mode" means concretely

A per-node runtime mode, decided by the operator and carried in the node map /
config, such that:

* the master's `post_proxy_write` skips destinations in WAL mode;
* the replica runs a fetch/apply controller (§3);
* the replica's read eligibility is decided on stream state, not on `Active`
  alone.

The mode must be **fail-closed**: if the replica cannot confirm it is in WAL
mode, or the master cannot confirm the destination is, the write path falls
back to today's proxy behaviour rather than silently dropping both.

---

## 3. Safety conditions and how each is met

| # | Condition | Design | Test (§6) |
|---|---|---|---|
| 1 | The cursor advances only over **contiguously applied** history | Only `apply_batch_with_lsn` moves it, per batch, in sequence order. Neither the arrival of a newer value by another route nor a read of the master's position may set it. The follower refuses a response whose first sequence is not the expected successor of its cursor. | T2, T4, T5 |
| 2 | Data and cursor stay consistent across a crash | Unchanged: one merged `WriteBatch`. Durability scope stated: process crash safe by default; host/power loss bounded by `rocksdb-sync-writes` (default off). Position seeding on the snapshot path stays inside the swap. | T4 |
| 3 | A disconnection never loses the repair requirement | The follower reconnects on its own schedule **without needing new writes**, resuming from its cursor; it never depends on the operator recreating the pod. A mid-stream disconnect resumes from the cursor instead of falling back to a rebuild (§1.6.4 changes). | T2, T3, T5, T8 |
| 4 | Missing history is never success | `lsn_purged` (and `lsn_ahead`, `master_id_mismatch`) transition the replica to **needs-rebuild**, never to "following". A node that is not following is not a healthy copy for promotion or for deletion decisions. | T6, T7 |
| 5 | No gap between initial copy and continuous fetch | Initial copy for WAL mode is the **snapshot path** (`create_snapshot_checkpoint` → `swap_in_snapshot` seeds cursor = checkpoint sequence). The full-dump seeding of §1.7 is **not** an acceptable entry into continuous mode; if a dump is used, the cursor must be the master's sequence captured at dump start **and** the replica must stay out of the write/read path until catch-up reaches the master's position at that time. | T1 |
| 6 | Stale sources and stale sessions are refused | Session identity = (master_id, master boot/generation token). Checked at connect **and** carried per response; the applier rejects a batch whose session token differs from the one the cursor belongs to. Not claimed as writer fencing (§0.2.5). | T7 |
| 7 | Bounded resources | Per-response batch count and byte caps on the master (replacing the unbounded `get_updates_since` vector), existing per-batch size ceiling, bandwidth limit and interval, bounded reconnect backoff, and a WAL retention cap that **prefers rebuilding a slow replica over exhausting the master's disk**. | T9 |

---

## 4. Operator interface

flared owns delivery and reconnection. The operator observes and decides.

### 4.1 Observations to add (stats keys)

| Key | Meaning |
|---|---|
| `repl_follow_source` | peer being followed (`host:port`), empty when not following |
| `repl_follow_master_id` / `repl_follow_session` | lineage and session token the cursor belongs to |
| `repl_applied_lsn` | contiguously applied position (today's `rocksdb_repl_last_lsn`) |
| `repl_source_lsn` / `repl_source_lsn_observed_at` | master position **and when it was observed** — never a bare number |
| `repl_follow_state` | `initial_sync` / `following` / `disconnected` / `needs_rebuild` / `error` |
| `repl_last_progress_at` | last time the cursor advanced |
| `repl_last_reason` | reason code for the last reconnect or rebuild (`lsn_purged`, `master_id_mismatch`, `crc_mismatch`, `peer_unreachable`, …) |

### 4.2 What must not be treated as evidence

`Active`, a successful TCP connection, and a past reconstruction success are
**not** evidence of being caught up. An observation that is missing or older
than a bound is **Unknown**, never "healthy" (this is the SAF-04 typing rule,
extended to stream state).

### 4.3 Separate eligibility

* **Serving reads**: `following` **and** lag within a configured bound, from a
  fresh observation. Default for stage 1: WAL-mode replicas do not serve
  reads.
* **Promotion**: `following` with a fresh observation and lag under a
  promotion bound. Because replication is asynchronous, **it can never be
  proven that the replica had everything the master acknowledged** — when the
  master is unreachable this remains unprovable, and today's
  availability-first promotion must not be described as loss-free.
* **Deleting another copy**: unchanged gate (EV-05) plus a requirement that at
  least one other copy is `following` and fresh.

### 4.4 Coordination with the replica-repair ledger

The continuous stream and the ledger must not both rebuild the same replica:

* A WAL-mode destination produces no `proxy_write_dropped` (no proxying), so
  the ledger's trigger is inert by construction — it must be **explicitly
  suppressed** for WAL-mode nodes rather than left to chance, and the
  suppression must be visible in the ledger's own log.
* `needs_rebuild` from the stream is the single owner of the rebuild decision
  for WAL-mode nodes; the operator drives it through the existing
  demote → hold → reseat path so only one reconstruction runs (the existing
  completion record already prevents an older handler from claiming a newer
  one's success).

---

## 5. STAMP/STPA additions

To be added to `STPA-node-state.md` **without renaming or redefining existing
IDs** (the register's rule).

Control structure (§3 of that document) gains:

* **Master WAL production and retention** (controlled process) — control
  action A5: retain/purge WAL history; feedback: retention size/age, oldest
  available sequence.
* **Replica fetch/apply controller** (controller inside flared) — control
  action A6: connect/fetch/apply/reconnect/declare-rebuild; feedback F7:
  applied position, stream state, last progress, reason.
* **Operator read/promote/delete decisions** already exist as A1/A2/A4 and now
  consume F7.

Proposed new UCAs (next free IDs, UCA-19…):

| ID | Action | Timing | Unsafe control action | Hazards | Constraint |
|---|---|---|---|---|---|
| UCA-19 | A6 | Not provided | Fetch is not resumed after a transient disconnection | H3 | Reconnect and catch up without depending on new writes or on pod recreation |
| UCA-20 | A6 | Provided | The applied position advances past a range that was not applied | H2, H3 | Contiguity requirement + atomic position write |
| UCA-21 | A6 | Provided | A batch from an old session/lineage, or out of order, is applied | H2, H3, H6 | Session/lineage/order validation at apply time, not only at connect |
| UCA-22 | A6 | Provided | A replica whose required history is gone is treated as synchronised | H2, H3 | `lsn_purged` ⇒ explicit needs-rebuild state; never "following" |
| UCA-23 | A1b/A4 | Provided | A lagging or unobservable replica is treated as safe for reads/promotion/other-copy deletion | H2, H4, H5 | Purpose-specific eligibility with Unknown handling |
| UCA-24 | A5 | Not provided | WAL is retained until the master's disk is exhausted | H1, H5 | Retention ceiling with a safe switch to rebuild |

Register: relate to **SC-03/EV-03** (repair of a diverged replica),
**SC-04/EV-04** (synchronisation evidence), **SC-13/EV-13** (durability
bounds — this design is the concrete answer SC-13 asks for), observation to
**EV-11/EV-15**, content verification to **EV-12**, deletion impact to
**EV-05**. Constraints that do not fit an existing claim get **new** IDs
(proposed: SC-14 "continuous fetch resumes without external intervention",
SC-15 "applied position is contiguous and crash-atomic", SC-16 "history loss
is an explicit rebuild state") with matching EV entries. **No existing ID's
meaning is changed.**

---

## 6. Acceptance tests

RocksDB backend. The replica is inspected **directly** (stats and gets on the
replica pod); a proxied read through the master is never accepted as evidence,
because `op_get` proxies a miss to the master and hides a local gap. Assertions
cover the expected **key set, values, versions and delete outcomes**, not
counts alone. The existing `iptables`-on-the-kind-node helper
(`cutMasterToSlave` / `heal` in `E2E/Tests/ReplicaRepair.lean`) provides a real
link cut, and each test must record: the evidence that the cut happened, the
operations the master accepted while it was cut, the position the replica
resumed from, and the final content.

| ID | Scenario |
|---|---|
| T1 | Writes continue **during** the initial snapshot; after the hand-off to continuous fetch the replica matches exactly (no gap at the boundary) |
| T2 | Link cut; creates, updates and deletes on the master meanwhile; after healing the replica converges automatically |
| T3 | Same as T2 but **no further writes** after healing — catch-up must still happen (this is the "needs no new writes" requirement) |
| T4 | Disconnect mid-batch, and replica process crash at an apply boundary — recovery with data and cursor consistent, no duplicate or missing effect |
| T5 | Repeated disconnections — no loss, no rollback, no resurrection of deleted keys |
| T6 | Replica outside the WAL retention window recovers automatically via snapshot + WAL, and is not reported as synchronised in between |
| T7 | After a master change / lineage regeneration, batches from the old connection are refused |
| T8 | Operator restart does not disturb replication progress |
| T9 | A slow replica stays within the configured resource limits (master memory/disk, bandwidth) |

Expiry is verified under controlled time conditions. No fixed sleep and no
"absence of a log line" is accepted as a pass condition.

---

## 7. Staging, evidence and CI

SAF-10 is decomposed (SAF-11 is the separate circuit-breaker finding):

* **SAF-10a — audit and design** (this document; reviewable now).
* **SAF-10b — delivery and resume** (flared: follow mode, bounded fetch,
  contiguity, session validation, reconnect, rebuild transition).
* **SAF-10c — operator interface** (stats keys, eligibility split, ledger
  coordination).
* **SAF-10d — acceptance tests** (T1…T9) and evidence.

Each stage records in the register: hazard/constraint → production code path →
test → executed SHA and report → reviewer assessment. `implementation` and
`verification` stay separate; nothing is marked `verified` by the author.
Unit tests and a small RocksDB link-cut E2E go into the PR's CI; long-running
and retention-expiry tests may run outside it and are then **explicitly
recorded as not run**. One feature branch, staged commits.

---

## 8. Open questions for the reviewer

1. **Option A vs B** (§2) — is replacing op-level proxying for WAL-mode
   replicas acceptable, given that it makes replica reads lag-bounded?
2. **Failover cost** (§1.3): surviving replicas rebuild after a promotion.
   Accept for stage 1, or design per-source cursors first?
3. **Read eligibility default**: keep WAL-mode replicas out of the read set
   initially (proposed), or define a lag bound now?
4. **Retention policy** when a replica falls behind: at what point does the
   master stop retaining and force a rebuild (§3.7)?
5. **Reserved keys in the stream** (§1.2): a master's `master_id` Put replays
   onto the replica. Neutralise reserved keys on apply, or accept adoption?
6. Scope confirmation: Tokyo Cabinet, cross-partition and synchronous ACK stay
   out (§0.2).
