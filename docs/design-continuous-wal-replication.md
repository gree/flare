# Design: continuous WAL replication (RocksDB, intra-cluster master → replica)

Status: **DRAFT for review — audit and design only, no implementation.**
Scope owner: SAF-10 (stage SAF-10a). See §0.3 for the relation to
[design-wal-cluster-replication.md](design-wal-cluster-replication.md), which
is a different (cross-cluster, parked) design.

Revision 2 records the reviewer's decision: **both paths are kept** — op-level
forwarding for low-latency propagation, continuous WAL for gap-free recovery —
**and the current raw-`WriteBatch` apply is not permitted to run alongside
it**. §3 is the common apply rule that decision requires and is the gate for
SAF-10b.

---

## 0. What this is for

### 0.1 The requirement

While the master and its data survive, a temporary loss of connectivity to a
replica must not leave that replica permanently behind: after the link
returns, the replica must catch up **automatically and without gaps**. This
must hold during normal operation, not only during initial build, and must
survive disconnection and process restart on either side — the goal is not
"stay connected" but "resume from the applied position".

### 0.2 Scope

In scope: RocksDB ↔ RocksDB, same cluster, master → replica of the **same
partition**, **asynchronous**; incremental recovery while the needed WAL is
retained, automatic snapshot + WAL rebuild when it is not.

Explicitly **not** guaranteed, and not to be claimed as a consequence of this
design:

1. **No durability guarantee for acknowledged writes against master data
   loss.** Replication is asynchronous; a write the client was told was stored
   can be lost if the master's data is destroyed before it was fetched.
2. **No synchronous ACK**, hence no bounded staleness at acknowledgement time.
3. **No latest-read guarantee from coexistence.** Having both paths reduces
   propagation delay; it does not make a replica read fresh. Read eligibility
   is decided separately (§5.3).
4. **No support for a different partition assignment** between master and
   replica.
5. **No Tokyo Cabinet support** — the mechanism is RocksDB-specific.
6. **Not distributed writer fencing** (H6 / EV-01 unchanged).

### 0.3 Relation to the existing WAL design document

`design-wal-cluster-replication.md` designs **cross-cluster** WAL transport
for same-topology migration, is parked as DRAFT ("do not start"), and reused
`op_repl_sync_wal` as-is. This document is intra-cluster, same partition,
continuous, and — unlike that draft — does **not** apply batches verbatim.
The two must not be conflated in the register.

---

## 1. Audit of the current implementation

Read at commit `f568044` on branch `safety/saf-10-wal-replication`. Line
numbers are from that revision; symbols are given so they survive line drift.

### 1.1 WAL mechanism, LSN, and what an entry is

| Fact | Where |
|---|---|
| Replication uses **RocksDB's own WAL** via `GetUpdatesSince` / `TransactionLogIterator` | `storage_rocksdb::get_updates_since`, src/lib/storage_rocksdb.cc:1624 |
| The LSN is the **RocksDB sequence number of the whole DB on that node** — not per partition, not per key | `storage_rocksdb::get_latest_sequence_number`, src/lib/storage_rocksdb.cc:1617 |
| A stream unit is a `WriteBatch` plus its sequence, applied **verbatim**: no per-key decode, no partition filter, **no version comparison** | `storage_rocksdb::apply_batch_with_lsn`, src/lib/storage_rocksdb.cc:1743 |
| Consequence: the stream reproduces the source node's key set byte for byte, **including** keys that do not hash to this partition and **including reserved replication keys** | same |
| Every local storage write on the master is in its WAL — reaper deletes, orphan purge, expiry-driven deletes, `flush_all`'s truncate | RocksDB semantics; `storage.h:237-239` documents that storage-level removes are op-level-local |

`get_updates_since` reads **the whole iterator into a
`vector<pair<uint64_t, WriteBatch>>`** before anything is sent
(storage_rocksdb.cc:1640-1648): master memory is proportional to the
receiver's backlog.

### 1.2 Applied position (cursor) and crash consistency

* The cursor is a reserved key **inside the same RocksDB**
  (`kReplLastLsnKey`); read via `get_repl_last_lsn` (storage_rocksdb.cc:1783).
* `apply_batch_with_lsn` copies the incoming batch, **appends the cursor Put
  to that same batch**, and issues one `Write()` — data and cursor cannot
  disagree after a crash (storage_rocksdb.cc:1743-1760). This structural
  property is kept in §3.4; what changes is *what* goes into the batch.
* Because the cursor Put is appended last it wins over a cursor Put travelling
  inside the master's batch. **Other reserved keys are not neutralised**: a
  `kReplMasterIdKey` Put in the master's WAL is replayed onto the replica and
  silently rewrites its lineage token.
* `set_repl_last_lsn` (storage_rocksdb.cc:1798) is a *separate* durable Put,
  used only for seeding after a full dump — not atomic with the data it
  claims to describe (§1.7).
* Durability is governed by `rocksdb-sync-writes` (default **false**):
  process-crash safe; a host/power loss can lose the most recent writes on
  either side.

### 1.3 Lineage and generation

* `master_id` is a **per-DB UUID** under `kReplMasterIdKey`:
  `_load_or_generate_master_id` (storage_rocksdb.cc:215), `set_master_id`
  (262, `wo.sync = true`), `regenerate_master_id` (287) — the last is called
  at promotion when the replication cursor is ahead of the node's own
  sequence, deliberately breaking lineage so two incomparable sequence spaces
  are never compared.
* Server gates: `master_id_mismatch` (op_repl_sync_wal.cc:145-155),
  `lsn_ahead` (157-170). Client gate: WAL catch-up only when
  `repl_last_lsn > 0 && local master_id == peer master_id`
  (`handler_reconstruction::_try_wal_reconstruction`,
  src/lib/handler_reconstruction.cc:498-513). After a full dump the replica
  **adopts the peer's `master_id`** (handler_reconstruction.cc:~330).
* **Consequence:** the sequence space belongs to a DB. After a failover the
  new master's sequence space is unrelated to the one the survivors were
  following, so survivors cannot resume — they rebuild. Accepted for this
  stage (§0.2 and reviewer's instruction); per-source cursors are out of scope.

### 1.4 Retention and "history is gone"

`_wal_ttl_seconds` (default 86400) and `_wal_size_limit_mb` (default 10240),
storage_rocksdb.h:107-108. `GetUpdatesSince` → `NotFound` → `ERR_LSN_PURGED`
(storage_rocksdb.cc:1631-1636) → `lsn_purged` (op_repl_sync_wal.cc:172-177) →
client classifies (`client_lsn_purged`) and the caller rebuilds. **Already
fail-closed: purged history is never reported as synchronised.**

### 1.5 Transport today

`repl_sync_wal <lsn> <master_id>` — one request, one response. Server
(`op_repl_sync_wal::_run_server`, 129-287): lineage check → ahead check →
`get_updates_since` → per batch: structural validation
(`validate_batch_rep`), size ceiling (`batch_too_large`), `LSN <seq>`,
`BATCH <size> <crc32>`, raw bytes, optional throttle → `END`. Client
(296-470): `readsize()` per batch, **CRC verified before apply**, then
`apply_batch_with_lsn`; any error aborts with nothing written for that batch.
**There is no follow/tail mode** — the server never waits for new writes.

### 1.6 Reconstruction lifecycle (the only consumer today)

`handler_reconstruction::run` (src/lib/handler_reconstruction.cc:76): one
handler = one reconstruction id; in-handler retry 2,4,8,16,30…s up to 60
attempts; completion record (`reconstruction_begin` /
`succeeded_from(id,src)` / `failed_final(id)` / `aborted_by_shutdown(id)`).
`_run_once` (130): corruption self-heal → connect → try WAL → else snapshot
bootstrap → else truncate + full dump (with a "source is not newer" guard) →
adopt `master_id` → seed cursor → activate. **On success the handler exits;
nothing keeps pulling.** **Any** WAL failure — including a mid-stream
disconnect — falls back to a full rebuild (handler_reconstruction.cc:540-556),
although the applied cursor would allow resuming.

### 1.7 Initial copy → continuous hand-off

* **Snapshot path is gap-free.** `create_snapshot_checkpoint(out_path,
  out_seq)` (storage_rocksdb.cc:1037) captures the exact sequence;
  `swap_in_snapshot(staging, checkpoint_seq)` (1129) verifies the staged
  checkpoint read-only, swaps under the whole-lock, reopens, **seeds
  `repl_last_lsn = checkpoint_seq`**, rescans `curr_items` exactly, clears the
  corruption latch — and also **clears the in-memory tombstone cache**
  (`_clear_header_cache`, §1.9).
* **Full-dump path is not.** `_seed_repl_lsn_after_dump`
  (handler_reconstruction.cc:568) seeds the cursor with `peer_latest_lsn`
  probed **before** the dump started. Replaying from a pre-dump position is
  redundant for a quiescent replica and unsafe for one that also takes live
  writes. Per the reviewer's instruction the initial copy for a continuously
  replicating replica is **snapshot + WAL**; the dump path is not an entry
  into continuous mode.

### 1.8 Live write path, and who receives it

* The master forwards to the partition's **Active** slaves only
  (`cluster::post_proxy_write`, src/lib/cluster.cc:1570, over `p_tmp.slave`;
  `_reconstruct_node_partition`, cluster.cc:2146+, admits a slave to
  `npm[p].slave` only when `node_state == state_active`; Prepare/Ready slaves
  go to the separate prepare map). **A Prepare replica receives no live
  proxied writes** — activation is the moment two write paths could overlap.
* `queue_proxy_write::run` (src/lib/queue_proxy_write.cc) retries `max_retry`
  times, then logs and counts `proxy_write_dropped[<dest>]` — **the client was
  already told STORED**. There is **no per-write acknowledgement**.
* Ops are forwarded as **operations**: `incr`/`decr` via
  `pre/post_proxy_write` with the operand (op_incr.cc:156, 189); `delete`
  likewise (op_delete.cc:97, 128); the reaper replicates its deletes as
  version-carrying proxied deletes. `flush_all` is **not proxied at all**
  (`op_flush_all::_run_server` only calls `storage->truncate()`), and
  `orphan_purge` is local-only — two existing divergence sources that a
  change-level WAL stream removes.

### 1.9 Versions and delete history — is `version` enough?

This is the question the reviewer asked, answered from code.

**How a version is produced** (`storage_rocksdb::set`, src/lib/storage_rocksdb.cc:385):

* client write arrives with `version == 0` → `e.version = e_current.version + 1`
  (the master assigns; per-key counter stored in the entry header,
  `entry::header_size`, storage.h:141);
* a **proxied** write arrives with the master's version; behaviour flags are
  0, so the guard applies:
  `if ((e_current_st == st_alive || (b & behavior_dump)) && e.version <= e_current.version) → skip`;
* `cas` compares equality then increments; **`touch` does not change the
  version** (`e.version = e_current.version`).

**Delete history** (`storage_rocksdb::remove`, storage_rocksdb.cc:682): the
key is physically `Delete`d and the version is remembered by
`_set_header_cache(key, e)` — an **in-memory `tcmap`** (storage.cc:320)
bounded by count (`tcmapcutfront` when over `_header_cache_size`), consulted
by `_get_header` on NotFound, **not persisted**, and wiped by
`_clear_header_cache()` (storage.h:488) on snapshot swap.

**Verdict, case by case:**

| Case | Is `version` sufficient? | Why |
|---|---|---|
| Update of a live key (set/replace/append) | **Yes** | strict `e.version <= current → skip`: duplicate and out-of-order sets are rejected |
| `delete` of a live key | **Yes** while the key exists | `e.version < current → skip` (remove(), storage_rocksdb.cc:705) |
| **delete → older `set`** (resurrection) | **No** | after the delete the state is `st_gone` (the cached tombstone's `expire` is the delete time, so `expire > now` is false), and the version guard is applied only for `st_alive` **or** `behavior_dump`. A normal proxied set with an older version is therefore **accepted and resurrects the key** |
| delete → re-create → older update | **No** | same gap; the re-created key's version restarts from the tombstone only while the tombstone is in memory |
| Tombstone lifetime | **No** | in-memory, count-bounded, lost on restart, cleared by snapshot swap — the same stale set is rejected or accepted depending on cache pressure and uptime |
| `touch` | **No** | version is deliberately unchanged, so two touches, or a touch versus a concurrent set, cannot be ordered by version |
| `incr` / `decr` | **No** | forwarded as an operation and recomputed on the replica; applying it twice, or in the wrong order relative to a set, gives a different value. Version does not identify the operation |
| Internal deletes (reaper, expiry, `orphan_purge`, `flush_all`) | **Partly** | the reaper forwards version-carrying deletes; `orphan_purge` and `flush_all` do not replicate at the op level at all |
| Across a master change | **No** (inference from code, not staged) | the version is a per-key counter carried in the data. A replica that missed writes holds a **lower** version; once promoted it assigns `current + 1`, which can be **below** a version already present on another surviving copy, so its later writes are rejected there as "older" — divergence that only a rebuild clears |

**Conclusion: `version` is sufficient for ordering updates of a live key and
nothing else.** A common apply rule cannot be built on it alone.

### 1.10 What the operator can observe today

`stats` (src/lib/op_stats.cc:169-240): reconstruction counters and the
completion record (`reconstruction_boot_id`, `_current_id`, `_current_state`,
`_last_success_id`, `_last_success_source`), `rocksdb_master_id`,
`rocksdb_repl_last_lsn`, `rocksdb_latest_sequence_number`, WAL error counters,
`rocksdb_snapshot_bootstrap`, `rocksdb_corrupted`,
`rocksdb_resync_failure_count`, `proxy_write_dropped[dest]`. Missing: which
peer is followed, stream state, master position **with observation time**,
last progress time, reason codes (§5.1).

---

## 2. Replication paths: the decision

**Chosen (reviewer):** keep **both** paths.

* **Op-level forwarding** stays the low-latency propagation path.
* **Continuous WAL** is the gap-free recovery path: it delivers everything,
  in master commit order, including what forwarding dropped and what
  forwarding never carried (`orphan_purge`, `flush_all`, expiry/reaper
  deletes that were not forwarded).

**Not permitted:** today's verbatim `apply_batch_with_lsn` running alongside
the forwarding path. Two writers applying to the same keys with no common
ordering rule is precisely the order-inversion / resurrection / double-apply
surface, and the verbatim path has no per-key decision at all — it overwrites.

**Therefore both paths must produce the same, identified change and go through
one apply rule (§3).** SAF-10b does not start before that rule is reviewed.

---

## 3. Common change identity and apply rule

### 3.1 Change identity

The master's RocksDB sequence number is already a **total order over every
change the master commits**, and both paths originate at that same commit:

* **WAL path:** a batch carries its sequence; RocksDB assigns consecutive
  sequence numbers to the entries inside a batch, so the *i*-th decoded change
  of a batch starting at `S` has identity `S + i`.
* **Forwarding path:** the master reads its own sequence immediately after the
  local write, while still holding that key's slot lock, and sends it with the
  op.

Identity of a change: **`(session, src_seq)`** where `session` is
`(master_id, master boot/generation token)` and `src_seq` is that sequence.
`session` makes sequences from different DBs or different processes
incomparable instead of silently comparable.

*Why the forwarding path's `src_seq` is sound even though it is read after the
write:* another key's write may bump the DB sequence between our write and our
read, so the reported value can be **greater than** the change's true
sequence. It can never be greater than the sequence of the **next write to the
same key**, because that write must first take the same per-key slot lock,
which we still hold. Per-key monotonicity — all the rule needs — is therefore
preserved, and the WAL copy of the same change carries a value `≤` the
forwarded one, which the rule treats as "already applied" (§3.3, case c).
This argument is a precondition for SAF-10b and must be pinned by a test
(T10), not assumed.

### 3.2 What a change is

Both paths are decoded into the same logical form before anything is written:

    change := { key, type ∈ {put, delete}, value?, flag, expire, version, session, src_seq }

* **WAL path:** `WriteBatch::Iterate` with a handler that turns `PutCF` /
  `DeleteCF` / `SingleDeleteCF` into changes, parsing flare's serialized entry
  header for `flag/expire/version`. Raw batches are **never** handed to
  `Write()` any more.
* **Forwarding path:** the op already carries key, value, flag, expire and
  version; `incr`/`decr` are converted **at the master** into the resulting
  value (a put), so no replica ever recomputes them.
* **Reserved keys** (`kReplLastLsnKey`, `kReplMasterIdKey`, anything
  `is_reserved_key`) are **dropped by the decoder** and never applied as data;
  the cursor is written by the applier itself and lineage is changed only by
  the explicit paths in §3.6.

### 3.3 The apply rule

Per key `K`, the replica keeps `applied_src(K) = (session, src_seq)` of the
last change it applied, and for a deleted key a **persistent tombstone**
carrying the same. For an incoming change `C`:

a. `C.session ≠ current session` → **refuse** (stale source / different
   lineage). Not fencing (§0.2.6): it rejects streams, it does not exclude a
   second writer.
b. `C.src_seq > applied_src(K).src_seq` → **apply** (put, or delete leaving a
   tombstone with `C.src_seq`).
c. `C.src_seq ≤ applied_src(K).src_seq` → **skip as already superseded**. This
   is the only legitimate way a change is skipped; it is not an error, and it
   is what makes the two paths idempotent with respect to each other.

Consequences, by the hazards the reviewer named:

* **Forwarded newer value, then older WAL batch** → case (c): skip. The
  replica never regresses.
* **delete → older put** → the tombstone holds `src_seq` of the delete, so the
  older put is case (c): skip. The resurrection of §1.9 is closed **by the
  rule**, not by the in-memory header cache.
* **duplicate delivery of the same change** (both paths, or a WAL re-fetch
  after a disconnect) → case (c): skip.
* **`touch`** carries its own `src_seq`, so it orders against sets without
  needing a version bump.
* **`incr`/`decr`** are values by the time they leave the master, so double
  application is a no-op instead of a double increment.

`version` is retained for its existing client-visible semantics (`cas`,
client conflict results). It is **not** the replication ordering key.

### 3.4 Cursor semantics and crash consistency

* **A successful forwarded write never advances the WAL cursor.** The cursor
  means "every change up to here has been fetched from the WAL and decided",
  which a forwarded write says nothing about. (Forwarded writes are applied
  *ahead* of the cursor; the WAL later re-delivers them and they are skipped.)
* The applier processes a fetched batch by building **one RocksDB
  `WriteBatch`** containing: the changes that passed the rule, their
  `applied_src` metadata, tombstone updates, **and** the new cursor value —
  then one `Write()`. A batch in which every change was skipped still writes
  the cursor, alone.
* Therefore: a crash **after applying and before saving the cursor is
  impossible**; a crash before the `Write()` loses nothing and the same batch
  is re-fetched and re-decided (the rule is idempotent). This preserves the
  property `apply_batch_with_lsn` has today (§1.2) while replacing verbatim
  application.
* The cursor advances **only over contiguously fetched history**: the applier
  refuses a response whose first sequence is not the expected successor of its
  cursor.
* Durability scope is unchanged and must be stated wherever the guarantee is:
  process-crash safe by default; `rocksdb-sync-writes` decides host/power-loss
  behaviour.

### 3.5 When delete history can be dropped

A tombstone exists to reject a change that is older than the delete. It can be
dropped for key `K` with delete sequence `D` only when no such change can
still arrive:

1. **From the WAL path:** the applied cursor is `≥ D`. The stream is ordered
   and is only ever fetched forward from the cursor, so no `src_seq < D` can
   be delivered afterwards. (A rebuild resets the whole DB and is therefore
   not a counter-example.)
2. **From the forwarding path:** a forwarded change older than `D` can only be
   in flight inside the bounded retry window of `queue_proxy_write`
   (`max_retry` attempts with bounded connect/op timeouts, plus queue wait).
   Define `T_inflight` as that bound; require `now − walltime(D) > T_inflight`.

Both conditions, and a persistent store: tombstones must survive a restart (an
in-memory, count-bounded cache cannot carry this rule — §1.9). Sweeping is a
background job over the tombstone space, with its own bound on size so a
delete-heavy workload cannot grow it without limit; if the bound is hit, the
safe action is to **rebuild the replica**, never to drop a tombstone early.

### 3.6 Reserved keys and lineage

Reserved keys are managed explicitly, never as replicated data:

* the cursor is written only by the applier (§3.4);
* `master_id` / session changes only through the explicit reconstruction and
  promotion paths (`set_master_id`, `regenerate_master_id`); a `master_id` Put
  arriving inside a WAL batch is **dropped by the decoder** and, because it
  indicates the source's lineage changed mid-stream, raises the
  `needs_rebuild` state rather than being applied.

### 3.7 Where the per-key replication metadata lives

`applied_src(K)` and tombstones need a home. Options, with costs — **a
decision is required before SAF-10b**:

| Option | Cost | Note |
|---|---|---|
| Extend the entry header with `session_id + src_seq` | on-disk format change (`entry::header_size`), touches dump/serialisation and the tch backend's shared code | smallest write amplification; largest blast radius |
| A dedicated RocksDB **column family** for replication metadata | one extra write per change, atomic in the same `WriteBatch`; tombstones live here naturally with their own GC | isolated from the data format, RocksDB-only — matches the scope |
| A parallel key namespace in the default CF | same as above but shares compaction and iteration with data; needs reserved-key filtering everywhere | cheapest to build, dirtiest to live with |

Recommendation: **the column family**, because it is atomic with the data
write, invisible to the tch code path, and gives tombstone GC its own space.

---

## 4. Safety conditions and how each is met

| # | Condition | Design | Test (§7) |
|---|---|---|---|
| 1 | The cursor advances only over **contiguously applied** history | §3.4; a forwarded write never advances it; a non-successor response is refused | T2, T4, T5, T10 |
| 2 | Data and cursor stay consistent across a crash | §3.4 single `WriteBatch`; durability scope stated (`rocksdb-sync-writes`) | T4 |
| 3 | A disconnection never loses the repair requirement | The follower reconnects on its own schedule **without needing new writes**, resuming from its cursor; a mid-stream disconnect resumes rather than rebuilding (changes §1.6) | T2, T3, T5, T8 |
| 4 | Missing history is never success | `lsn_purged` / `lsn_ahead` / `master_id_mismatch` ⇒ **needs_rebuild**, never "following"; such a node is not a healthy copy for promotion or deletion decisions | T6, T7 |
| 5 | No gap between initial copy and continuous fetch | Snapshot path only: `create_snapshot_checkpoint` → `swap_in_snapshot` seeds the cursor with the checkpoint sequence; the dump path is not an entry into continuous mode (§1.7) | T1 |
| 6 | Stale sources and stale sessions are refused | §3.3(a) at connect **and** per change at apply time | T7 |
| 7 | Bounded resources | Per-response batch/byte caps replacing the unbounded `get_updates_since` vector, existing per-batch ceiling, bandwidth and interval limits, bounded reconnect backoff, tombstone-space bound, and a retention ceiling that prefers rebuilding a slow replica over exhausting the master's disk | T9 |

---

## 5. Operator interface

flared owns delivery and reconnection; the operator observes and decides.

### 5.1 Observations to add (stats keys)

| Key | Meaning |
|---|---|
| `repl_follow_source` | peer being followed (`host:port`), empty when not following |
| `repl_follow_session` | `(master_id, generation)` the cursor belongs to |
| `repl_applied_lsn` | contiguously applied position |
| `repl_source_lsn` / `repl_source_lsn_observed_at` | master position **and when it was observed** — never a bare number |
| `repl_follow_state` | `initial_sync` / `following` / `disconnected` / `needs_rebuild` / `error` |
| `repl_last_progress_at` | last time the cursor advanced |
| `repl_last_reason` | reason for the last reconnect or rebuild (`lsn_purged`, `master_id_mismatch`, `crc_mismatch`, `peer_unreachable`, …) |
| `repl_forward_applied` / `repl_forward_skipped` | changes applied / skipped by rule (c) from the forwarding path |
| `repl_wal_skipped_superseded` | WAL changes skipped because forwarding had already applied them — the coexistence health signal |
| `repl_tombstones` | live tombstone count (resource bound, §3.5) |

### 5.2 What must not be treated as evidence

`Active`, a successful TCP connection, and a past reconstruction success are
**not** evidence of being caught up. A missing or stale observation is
**Unknown**, never "healthy".

### 5.3 Separate eligibility

* **Serving reads**: `following` **and** lag within a configured bound from a
  fresh observation. Coexistence alone is explicitly not a freshness argument
  (§0.2.3). Default for stage 1: unchanged read balance, decided separately.
* **Promotion**: `following`, fresh observation, lag under a promotion bound.
  Because replication is asynchronous, **it can never be proven that the
  replica held everything the master acknowledged**; when the master is
  unreachable this stays unprovable, and availability-first promotion must not
  be described as loss-free.
* **Deleting another copy**: the existing gate (EV-05) plus a requirement that
  another copy is `following` and fresh.

### 5.4 Coordination with the replica-repair ledger

With both paths live, `proxy_write_dropped` still fires — and the continuous
stream will repair the same gap by itself. To avoid two rebuilds of one
replica:

* the stream's `needs_rebuild` is the **only** owner of the rebuild decision
  for a continuously replicating node;
* a drop counted for such a node is recorded and **explicitly held** by the
  ledger with a visible reason ("covered by continuous replication"), and
  closed when the applied position passes the drop's sequence — which is the
  same evidence the ledger already wants, expressed in sequences instead of
  reconstruction counters;
* if the stream is not `following`, the ledger keeps its current behaviour.

---

## 6. STAMP/STPA additions

To be added to `STPA-node-state.md` **without renaming or redefining existing
IDs**.

Control structure gains: **master WAL production and retention** (A5:
retain/purge; feedback: oldest available sequence, retention usage);
**replica fetch/apply controller** (A6: connect/fetch/decide/apply/reconnect/
declare-rebuild; feedback F7: applied position, stream state, last progress,
reason, skip counters); the operator's A1/A2/A4 now consume F7.

Proposed new UCAs (next free IDs):

| ID | Action | Timing | Unsafe control action | Hazards | Constraint |
|---|---|---|---|---|---|
| UCA-19 | A6 | Not provided | Fetch is not resumed after a transient disconnection | H3 | Reconnect and catch up without new writes and without pod recreation |
| UCA-20 | A6 | Provided | The applied position advances past a range that was not applied — e.g. a forwarded write is taken as evidence of WAL progress | H2, H3 | §3.4: forwarding never advances the cursor; contiguity required |
| UCA-21 | A6 | Wrong order | **A newer value arrives by forwarding and an older WAL change is then applied over it** | H2, H3 | §3.3(c): compare `src_seq` per key; skip superseded |
| UCA-22 | A6 | Wrong order | **A delete is applied and an older put then resurrects the key** | H2, H3 | §3.3 + §3.5: persistent tombstone with the delete's `src_seq`; defined GC bound |
| UCA-23 | A6 | Provided | **The process crashes after applying changes and before the position is saved**, so the same range is re-applied or skipped inconsistently | H2, H3 | §3.4: changes, metadata, tombstones and cursor in one `WriteBatch`; idempotent re-decision |
| UCA-24 | A6 | Provided | A batch from an old session/lineage is applied | H2, H3, H6 | §3.3(a) at connect and per change |
| UCA-25 | A6 | Provided | A replica whose required history is gone is treated as synchronised | H2, H3 | `lsn_purged` ⇒ needs_rebuild |
| UCA-26 | A1b/A4 | Provided | A lagging or unobservable replica is treated as safe for reads/promotion/deletion | H2, H4, H5 | §5.3 purpose-specific eligibility, Unknown handling |
| UCA-27 | A5 | Not provided | WAL is retained until the master's disk is exhausted | H1, H5 | Retention ceiling with a safe switch to rebuild |

Register: relate to **SC-03/EV-03**, **SC-04/EV-04**, **SC-13/EV-13**,
observation to **EV-11/EV-15**, content verification to **EV-12**, deletion
impact to **EV-05**. New IDs proposed: **SC-14** (continuous fetch resumes
without external intervention), **SC-15** (applied position is contiguous and
crash-atomic, and no other path may advance it), **SC-16** (history loss is an
explicit rebuild state), **SC-17** (both delivery paths apply through one
identified-change rule; no path may reorder, duplicate or resurrect), each
with a matching EV entry. **No existing ID's meaning is changed.**

---

## 7. Acceptance tests

RocksDB backend, replica inspected **directly** (stats and gets on the replica
pod) — a proxied read is never accepted as evidence, because `op_get` proxies
a miss to the master and hides a local gap. Assertions cover the expected
**key set, values, versions and delete outcomes**. The existing
`iptables`-on-the-kind-node helper (`cutMasterToSlave` / `heal`,
`E2E/Tests/ReplicaRepair.lean`) provides a real cut. Each test records: the
evidence the cut happened, the operations the master accepted meanwhile, the
position the replica resumed from, and the final content. No fixed sleep and
no "absence of a log line" is a pass condition.

| ID | Scenario |
|---|---|
| T1 | Writes continue **during** the initial snapshot; after the hand-off the replica matches exactly |
| T2 | Link cut; creates, updates and deletes meanwhile; after healing the replica converges automatically |
| T3 | As T2 but **no further writes** after healing — catch-up must still happen |
| T4 | Disconnect mid-batch, and replica crash at an apply boundary — data, per-key metadata, tombstones and cursor consistent; no duplicate or missing effect |
| T5 | Repeated disconnections — no loss, no rollback, no resurrection |
| T6 | Replica outside the retention window rebuilds automatically and is not reported synchronised in between |
| T7 | After a master change / lineage regeneration, changes from the old connection are refused |
| T8 | Operator restart does not disturb replication progress |
| T9 | A slow replica stays within the configured resource limits (master memory/disk, bandwidth, tombstone space) |
| T10 | **Coexistence rule**: forwarded newer value then older WAL delivery leaves the newer value; delete then older put leaves the key deleted; the same change delivered by both paths is applied once (`repl_wal_skipped_superseded` moves); `touch` and `incr` cross-deliveries give the same result as a single application |

Expiry is verified under controlled time conditions.

---

## 8. Staging, evidence and CI

* **SAF-10a — audit and design** (this document, including §3; review gate).
* **SAF-10b — delivery, resume and the common apply rule** (flared: decode,
  identity, rule, metadata store, tombstone GC, follow mode with bounded
  responses, contiguous crash-atomic cursor, session validation, reconnect,
  rebuild transition, resource ceilings).
* **SAF-10c — operator interface** (stats keys, eligibility split, ledger
  coordination).
* **SAF-10d — acceptance tests** (T1…T10) and evidence.

Each stage records: hazard/constraint → production code path → test → executed
SHA and report → reviewer assessment. `implementation` and `verification` stay
separate; nothing is marked `verified` by the author. Unit tests and a small
RocksDB link-cut E2E run in the PR's CI; long-running and retention-expiry
tests may run outside it and are then **explicitly recorded as not run**. One
feature branch, staged commits.

---

## 9. Open questions for the reviewer

1. **Metadata home** (§3.7): dedicated column family (recommended), header
   extension, or parallel namespace?
2. **`T_inflight`** (§3.5): the bound on how long a forwarded change can still
   arrive. Derive it from `queue_proxy_write`'s retry and timeout settings and
   make it configuration, or fix it conservatively?
3. **Tombstone-space bound reached** (§3.5): rebuild the replica (proposed) or
   refuse writes? Rebuild loses no data but costs availability of that copy.
4. **`incr`/`decr` converted to values at the master** (§3.2): this changes
   what a replica receives on the forwarding path. Acceptable, or must the op
   form be preserved for compatibility?
5. **Read eligibility** (§5.3): define the lag bound now, or keep the current
   read balance until SAF-10c?
6. **Failover** (§1.3): rebuild survivors for this stage — confirmed; revisit
   per-source cursors later as a separate task?
