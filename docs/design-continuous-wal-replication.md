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

Revision 3 replaces the time-based tombstone GC with a **cursor-based
rejection of old forwarded changes** (§3.5), specifies the **serialization
from decision to apply** (§3.8), and states the **preconditions without which
the sequence comparison is unsound, with the counterexamples that break it**
(§3.9). The §9 policy questions are settled; what remains open there is listed
as such.

Revision 4 carries the reviewer's implementation conditions into the design:
two distinct generations (§3.1), the capture rule extended to **every** write
path with bulk operations handled by an epoch switch (§3.9(B)), the
serialization requirements that go beyond the atomic write (§3.8), the read-set
and repair-ownership corrections (§5.3, §5.4), and corrected constraint
numbering (§6). It is **not** an approval that the preconditions have been
shown safe; they are implementation conditions to be met and tested.

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

### 3.1 Identity: two generations, and label vs identity

**Two generations, with different jobs.** Folding them into one token confuses
"the history I am following changed" with "my own copy was replaced".

* **Source epoch** — identifies the **master's history**, i.e. the sequence
  space the labels live in. It changes when that history is replaced or
  reparented: promotion of a node to master, a DB swap on the master, a
  truncate/`flush_all`-class bulk operation (§3.9(B)). It does **not** change
  on an ordinary process restart: a restart preserves the same RocksDB and the
  same sequence space, so a follower must be able to reconnect and resume from
  its cursor without rebuilding.
* **Receiver incarnation** — identifies **this replica's copy**. It changes
  whenever the replica's own DB is replaced (snapshot swap, hard reset,
  truncate-before-dump). Its job is to invalidate everything that belongs to
  the previous copy: open streams, in-flight forwarded changes, and any apply
  still pending. A forwarded change or a stream response stamped with an older
  incarnation is refused. It, too, does not change on a plain restart.

A stream is admissible only when the peer's **source epoch** equals the one
the cursor belongs to; a delivery is admissible only when the **receiver
incarnation** it was issued against is still current.

**Change identity is not the same thing as the order label.** The forwarded
path cannot carry the WAL's exact number (§3.9(B)): what it reports is read
inside the key's critical section and may be **inflated** by other keys'
writes committed in between.

* **Order label** `L = (source_epoch, seq_label)`: comparable **per key**, and
  strictly increasing for successive changes to the same key. This is what
  §3.3 and §3.5 compare. It is an ordering device, **not** a position: the
  stored label of a key may exceed the true sequence of the data it describes.
* **Change identity** — "these two deliveries are the same change" — is
  **not** established by the label, and this design does not claim exact
  de-duplication. What the rule guarantees is weaker and sufficient:
  *a delivery that is not strictly newer than what the key already has is never
  applied*. The duplicate copy of a change is refused because it is not
  strictly newer, which has the same effect for a key-value store and does not
  require the two paths to agree on an identifier.
* The only **positional** truth is the applied cursor, which comes from the WAL
  alone. Lag and progress are computed from it, never from per-key labels.

### 3.2 What a change is

Both paths are decoded into the same logical form before anything is written:

    change := { key, type ∈ {put, delete}, value?, flag, expire, version,
                source_epoch, seq_label, receiver_incarnation }

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

A tombstone exists to reject a change older than the delete. Rather than
bounding how long such a change can still be *in flight* (a wall-clock
argument, and therefore an assumption about timeouts and queue depths), the
replica rejects it **by position**:

> **Cursor rule.** A change whose `src_seq ≤ applied_cursor` is **refused,
> whichever path delivered it.** Everything up to the cursor has already been
> fetched from the WAL and decided; re-deciding it can only undo a later
> decision.

The forwarding path is therefore subject to two tests, in this order: the
cursor test above, then the per-key test of §3.3. The consequence is that a
tombstone for key `K` with delete sequence `D` is needed only while
`applied_cursor < D`, and may be dropped as soon as **`applied_cursor ≥ D`** —
after that, any older forwarded change is refused by the cursor test alone.
No wall clock, no `T_inflight`, no assumption about the retry window.

Two further consequences worth stating:

* **Metadata absence becomes safe.** After a snapshot restore the per-key
  metadata is empty and the cursor is the checkpoint sequence, so every change
  older than the restore point is refused by the cursor test and every newer
  one is legitimately applied (see §3.9(D) for what must be cleared).
* **Tombstone space is bounded by replication lag, not by delete volume.**
  Only deletes in `(applied_cursor, master_latest]` need one. A replica that
  follows closely holds almost none; a far-behind replica holds more, which is
  itself a lag signal. The bound is still enforced (§4, condition 7): if it is
  exceeded the replica goes to `needs_rebuild` rather than dropping a
  tombstone early.

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

### 3.8 Serialization from decision to apply

The cursor test is only sound if the position cannot move between the test and
the write. This is part of the rule, not an implementation detail:

* One `_repl_apply_lock` (rwlock) per node.
  * The **WAL applier** takes it **exclusively** for its whole window:
    decode → per-key decisions → build the batch → `Write()` (changes, per-key
    metadata, tombstone updates and the cursor) → tombstone GC.
  * A **forwarded change** takes it **shared**, plus the existing per-key slot
    lock for the key it writes. Forwarded changes therefore stay concurrent
    with one another and serialized per key exactly as today.
* **The cursor value used by the test is read inside that critical section**,
  never carried over from earlier in the request. A value read before a queue
  wait, a retry or a lock acquisition is stale by definition and must not be
  used.
* Tombstone GC runs inside the WAL applier's exclusive window, so a tombstone
  can never be dropped while a forwarded change admitted against an older
  cursor is still between its decision and its write.
* The applier's exclusive window is bounded by the per-response batch and byte
  caps (§4, condition 7). **Byte caps alone do not bound lock hold time or
  writer starvation**, so both are measured and tested (T17), and the window
  carries its own cap independent of the response size.

Further requirements on the critical section, all of them testable:

* **One lock order, everywhere**: `_repl_apply_lock` → `_mutex_wholelock` →
  per-key slot locks in ascending slot index. Every path that takes more than
  one of these — the applier, forwarded apply, bulk operations, GC — uses that
  order.
* **Intra-batch visibility**: when a batch changes the same key more than
  once, the decision for a later change must see the earlier ones. The applier
  keeps an in-batch overlay (key → label, tombstone state) that is consulted
  before the persisted metadata and merged into it by the same `Write()`.
* **Release-build detection**: an operation the decoder does not support, or a
  count that disagrees with the batch's own, is detected in **release builds**
  — an explicit check with a counter, a log line and a transition to
  `needs_rebuild`, never a bare `assert` that a production build compiles out.
* **No network inside the exclusive section**: read and decode the response
  outside it; only decide + write + GC run inside. A stalled peer must never
  hold the write path.
* **GC is chunked**: a bounded number of tombstones per pass, resumable, so a
  large collection cannot extend one window.
* **Starvation is bounded**: forwarded writes must not be blocked indefinitely
  by a continuous stream of applier windows (writer-preference, or a cap on
  consecutive windows). The maximum observed forwarded-write wait is part of
  the acceptance evidence, not an assumption.

What this does **not** provide: cross-key consistency. Forwarded changes are
applied ahead of the cursor, so the replica's state is "newest per key", not a
snapshot of any single master point in time. No multi-key atomicity is
claimed, and none exists today either.

### 3.9 Preconditions, and the counterexamples that break the rule without them

The comparison rule is sound **only** under the four preconditions below. Each
is stated with the concrete case that breaks it, because each is easy to get
wrong and none of them shows up in a passing happy-path test.

**(A) `master_id` alone is not a session identity — a generation token is
required.**
`regenerate_master_id()` runs at promotion **only when the replication cursor
exceeds the node's own sequence** (src/lib/cluster.cc:1739). A replica rebuilt
by snapshot has `cursor == checkpoint_seq`, which is not greater than its own
latest sequence, so the condition is false and the token is **kept**. Promote
that replica and two different DBs — the old master and the new one —
advertise the **same `master_id` over unrelated sequence spaces**. A follower
that treated `master_id` as the session would compare its cursor, expressed in
the old master's space, against the new master's numbers: every comparison in
§3.3 and §3.5 becomes meaningless, and both "skip as superseded" and "apply"
can be wrong. *Required:* `session = (master_id, generation)` where the
generation changes on **every** DB replacement and **every** promotion,
unconditionally, and is compared before any number is.

**(B) The forwarded sequence must be captured inside the key's critical
section.**
If the master reads `GetLatestSequenceNumber()` after `storage::set()` has
returned — which is where forwarding happens today
(`cluster::post_proxy_write`, src/lib/cluster.cc:1570, called from the op
after the local write) — another operation on the same key can commit in
between:

> `set K=v1` commits at sequence 100 and releases the slot lock.
> `delete K` commits at 101.
> The set's forwarder now reads "latest = 101" and forwards `K=v1` stamped
> **101**; the delete's forwarder reads 101 or later and forwards the delete
> stamped **101** as well.
> The replica applies whichever arrives first and skips the other as "not
> greater". If the set wins, **the deleted key is resurrected**, and no later
> WAL delivery repairs it: the WAL carries 100 and 101, both `≤` the applied
> 101, so both are skipped.

*Required:* the label is read **inside** the storage call while the key's slot
lock is held, and travels with the entry. Under that rule the reported value
can still be inflated by other keys' writes, but it is **strictly monotonic
per key**: the next write to the same key must first take that lock, so its
own sequence already exceeds anything visible at the earlier read.

**The rule binds every path that can change a key, not only `set`.** A single
path that mutates a key while bypassing the label capture re-opens exactly the
counterexample above:

| Path | Entry point | How it complies |
|---|---|---|
| `set` / `add` / `replace` / `append` / `prepend` / `cas` | `storage::set` | label captured under the slot lock |
| `delete` | `storage::remove` | same |
| `touch` / `gat` | `storage::set` with `behavior_touch` | same; the label orders it even though the version is deliberately unchanged |
| `incr` / `decr` | `storage::incr` | same; the **resulting value** is forwarded (§3.2) |
| expire-driven lazy delete on read | the reaper's delete path | same — it is a `remove` |
| reaper background crawler | `storage::remove` per key | same, per key |
| `orphan_purge` | `storage::remove` per key | same, per key; it also becomes replicated, which it is not today |
| `flush_all` / `truncate` | `storage_rocksdb::truncate` under the whole-lock | **not** per key: handled by an epoch switch (below) |
| snapshot swap / hard reset | `swap_in_snapshot`, `hard_reset` | not per key: receiver incarnation changes (§3.1), deliveries for the old incarnation are refused |

**Bulk operations take the exclusive route.** `truncate` and `flush_all`
replace the history rather than edit keys within it: they take the whole-lock,
so no per-key label is meaningful, and ordering a mass delete against in-flight
forwarded changes by label would be guesswork. Instead the master **advances
its source epoch** when it performs one; followers see an epoch change, refuse
the old stream, and rebuild. That is a deliberate cost — a `flush_all` costs
every replica a rebuild — and it is the honest alternative to silently
diverging, which is what happens today (`flush_all` is not replicated at all,
§1.8).

**(C) Per-entry numbering must count exactly the sequence-consuming
operations.**
A batch starting at sequence `S` gives its *i*-th sequence-consuming entry the
identity `S + i`. If the decoder's count diverges from RocksDB's — an
operation that consumes a sequence and is not decoded, or a marker that is
decoded and does not — every change after the divergence in that batch is
mis-numbered, and a mis-numbered change can beat a genuinely newer one for the
same key. *Required:* the decoder handles exactly the sequence-consuming
operations and **asserts** that its count equals the batch's own count; a
mismatch refuses the batch and raises `needs_rebuild` (fail closed) instead of
applying it. On the master the observed batch size is 1 (each op issues a
single `Put`/`Delete`), so this is a guard against future change rather than a
present defect.

**(D) Inherited metadata must be cleared at a snapshot swap.**
`swap_in_snapshot` replaces the whole DB directory with the source's
checkpoint, so **the source's own replication metadata comes with it**: its
per-key applied sequences (which belong to *its* source's space, if it was
ever a follower) and its tombstones. Applying §3.3 against inherited values
compares numbers from two unrelated spaces. *Required:* the swap clears the
replication-metadata column family and the tombstone space and sets the cursor
to the checkpoint sequence — after which the absence of per-key metadata is
safe, because everything older than the restore point is refused by the cursor
test (§3.5).

*Also required — the initialisation must be all-or-nothing.* Until the
metadata is cleared, the cursor is set and both generations are written, the
node **accepts no delivery on either path** and does not present itself as a
copy. A crash part-way through must not leave a DB that is exposed with
inherited metadata or an unset cursor: the swap writes a completion marker
last, in the same batch as the cursor and the generations, and a DB whose
marker is absent at open is treated as an incomplete restore and rebuilt.

No counterexample was found that breaks the rule **with** these four
preconditions in place. The cases examined are pinned as T4, T5, T7 and
T10–T13 so the claim is testable rather than asserted.

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
| 7 | Bounded resources | Per-response batch/byte caps replacing the unbounded `get_updates_since` vector, existing per-batch ceiling, bandwidth and interval limits, bounded reconnect backoff, tombstone space bounded by replication lag (§3.5) with rebuild on overflow, and a retention ceiling that prefers rebuilding a slow replica over exhausting the master's disk | T9 |
| 8 | Delete history is dropped only when an older delivery has become impossible, and no decision is made against a stale position | §3.5 cursor rule + §3.8 serialization: the position is read inside the same critical section as the write, and GC runs inside the applier's exclusive window | T11, T12, T13 |

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

Implemented in SAF-10c as one pure module,
`flare_operator/FlareOperator/StateMachine/FollowEvidence.lean`
(`judge`, `classify`), fed by the replica's own `stats` reply and the
partition master's reply of the same pass. The verdict is one of
`notInMode` (the node is not a WAL-mode follower: nothing below applies),
`eligible`, `ineligible`, `unknown`. Unknown is never healthy.

* **Serving reads**: a WAL-mode replica is **out of the read set** (balance 0
  at commit, `K8sReconciler.withholdReads`, whatever `spec.readBalance.slave`
  says) unless it is `following` the master's **current source epoch**, the
  master's position was observed within `FLARE_FOLLOW_FRESH_SECS` (default 5)
  **by the node's own clock** (both timestamps come from one reply, so clock
  skew cancels), and `head − applied ≤ FLARE_FOLLOW_READ_LAG` (default 1000)
  with the head read from the master this pass. Coexistence is explicitly not
  a freshness argument (§0.2.3).
* **Planned promotion (drain)**: the same, under `FLARE_FOLLOW_PROMOTE_LAG`
  (default 100). A follower not proven is not a drain successor; the existing
  drain guard then keeps the master and reports it.
* **Failover (master gone)**: nothing can be proven — **it can never be proven
  that the replica held everything the master acknowledged**. The FSM still
  promotes for availability, but (a) a follower **known** to hold an unusable
  copy (`needs_rebuild`, `initial_sync`, `idle`, another epoch) is excluded
  from every promotion path, (b) proven-current followers are ordered first,
  highest applied position first, and (c) a promotion of an unproven
  follower is logged as **not loss-free** (`PROMOTION NOT LOSS-FREE`).
  Candidate shaping is partitionMap-only (`shapePromotionCandidates`), the
  same device as standby de-prioritisation, so the promotion functions and
  their proofs are unchanged.
* **Deleting another copy**: the existing gate (EV-05) plus
  `survivorFollowOk`: from the SAME fresh stats read at revalidation, the
  surviving follower must be `eligible` for survival (promotion bound) or not
  in the mode; `unknown` refuses.
* **Unknown handling**: an unreadable or incomplete reply withholds reads and
  blocks planned promotion and deletion, but never makes a node unfit — a
  stats hiccup must not remove the last failover candidate. The mode is
  remembered per node; a node once seen in the mode whose stats become
  unreadable is Unknown. **Residual**: a node never yet read is not withheld
  (withholding on the first hiccup would flap every non-WAL cluster's read
  balance at start-up); the TCP-side zombie-master guard
  (`Reconciler.findActiveSlaveForPartition`) does not consult this evidence.
* **Probe cost**: every non-Down Slave in the mode is probed each tick, the
  master of each such partition too; a node known to be out of the mode is
  re-probed every `FLARE_FOLLOW_PROBE_INTERVAL` ticks (default 30).

### 5.4 Repair ownership versus transient connection state

The whole point of this work is that a blip is recovered **without** a full
rebuild, so the two must not be conflated:

* **Ownership is a mode, not a connection state.** While a node is in
  continuous-replication mode, the stream owns its repair decision —
  regardless of whether the stream is momentarily `disconnected`. The
  replica-repair ledger records drops for such a node and **holds** them with a
  visible reason ("owned by continuous replication"), closing them when the
  applied position passes the drop's label. It does not start a
  reconstruction.
* **A disconnect is not a rebuild trigger.** `disconnected` means: reconnect,
  resume **from the cursor**, keep the data. Only an explicit
  `needs_rebuild` — history purged past the cursor, source epoch changed,
  integrity failure, incomplete restore — hands the node to the rebuild path,
  through the operator's existing demote → hold → reseat sequence so a single
  reconstruction runs.
* **Ownership ends only when the mode ends.** If continuous replication is
  disabled for a node, or the node leaves the partition, the ledger resumes its
  current behaviour. Losing the connection does not end ownership, and must not
  be allowed to, or a flapping link would produce repeated full rebuilds — the
  failure this design exists to remove.

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
| UCA-28 | A6 | Too early | **Delete history is discarded while a change older than the delete can still be applied** | H2, H3 | §3.5: drop a tombstone only once the cursor has passed the delete; a change at or below the cursor is refused whichever path delivered it |
| UCA-29 | A6 | Wrong order | **The apply decision is made against a position read before a stall, retry or lock wait**, so a change admitted against an old cursor is written after the cursor moved | H2, H3 | §3.8: one critical section for read-decide-write; GC inside the applier's exclusive window |
| UCA-30 | A6 | Provided | **After a rebuild, changes from the previous session, or metadata inherited from the source, are applied** | H2, H3, H6 | §3.9(A)(D): generation-bearing session compared first; metadata and tombstones cleared at the swap |
| UCA-31 | A6 | Provided | A key is changed by a path that does not capture an order label (bulk operation, internal delete), so the change cannot be ordered against the other delivery path | H2, H3 | §3.9(B): every per-key path captures under the slot lock; bulk operations switch the source epoch instead |
| UCA-32 | A6 | Provided | A transient disconnection is treated as a repair trigger and starts a full reconstruction | H3, H4 | §5.4: ownership is the mode, not the connection state; resume from the cursor first |
| UCA-33 | A6 | Provided | A partially initialised copy (metadata cleared, cursor or generation not yet written) accepts deliveries or is presented as a copy | H2, H5 | §3.9(D): completion marker written last, in the same batch; an unmarked DB is rebuilt |

Register: relate to **SC-03/EV-03**, **SC-04/EV-04**, **SC-13/EV-13**,
observation to **EV-11/EV-15**, content verification to **EV-12**, deletion
impact to **EV-05**. New IDs proposed, starting after the
highest in use (SC-15 / EV-15 exist today): **SC-16** (continuous fetch resumes
without external intervention, and a lost connection alone never triggers a
rebuild), **SC-17** (the applied position is contiguous and crash-atomic, and
no other path may advance it), **SC-18** (history loss is an explicit rebuild
state), **SC-19** (both delivery paths apply through one comparison rule; no
path may reorder, duplicate or resurrect, and every path that can change a key
participates in the label capture) and **SC-20** (delete history is discarded
only when the applied position makes an older delivery impossible, and the
decision is serialized with the write), each with a matching EV entry
**EV-16 … EV-20**. **No existing ID's meaning is changed.**

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
| T11 | **Old put after tombstone GC**: delete a key, let the cursor pass the delete so the tombstone is collected, then deliver a forwarded put older than the delete — it is refused by the cursor test and the key stays deleted (`repl_forward_skipped` moves) |
| T12 | **Stalled forwarded change across a GC**: hold a forwarded change before its decision, advance the WAL applier and tombstone GC past its sequence, then release it — it is refused, and nothing it carries resurrects or regresses a key. Proves the decision is not made against a position read before the stall (§3.8) |
| T13 | **Old session after a snapshot restore**: rebuild the replica by snapshot, then deliver a forwarded change from the previous session, and one from the same session older than the restore point — the first is refused on session, the second on the cursor; inherited per-key metadata and tombstones are gone (§3.9(D)) |
| T14 | **Bulk operation**: `flush_all` / `truncate` on the master advances the source epoch; the replica refuses the old stream and rebuilds rather than diverging silently, and no key survives on the replica that the master dropped |
| T15 | **Intra-batch repetition**: one WAL batch changes the same key twice (and delete-then-put); the decision for the later change sees the earlier one, and the result equals applying them in order |
| T16 | **Restart versus history change**: an ordinary process restart of master or replica resumes from the cursor with **no** rebuild; a history replacement (promotion, DB swap, bulk operation) does trigger one. Distinguishes the two generations (§3.1) |
| T17 | **Critical-section behaviour under load**: maximum applier window hold time, maximum forwarded-write wait, and absence of writer starvation are measured while a far-behind replica catches up; unsupported operation and count mismatch are detected in a **release** build |

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

## 9. Decisions, and what stays open

Settled by the reviewer (2026-09-16) and carried into SAF-10b:

1. **Per-key metadata home**: dedicated RocksDB **column family** (§3.7).
2. **Tombstone lifetime**: **no wall-clock bound** — the cursor rule of §3.5
   replaces `T_inflight` entirely.
3. **Tombstone space exceeded**: **rebuild the replica**; never drop early.
4. **`incr`/`decr`** are converted to values at the master before forwarding.
5. **Read eligibility**: decided separately in SAF-10c; coexistence alone is
   never a freshness argument.
6. **Failover**: survivors rebuild at this stage; per-source cursors stay a
   separate task.

Open, and to be answered inside SAF-10b rather than before it:

* where the **source epoch** and the **receiver incarnation** (§3.1) are
  persisted and advertised, and the guarantee that each changes on exactly its
  own events and not on a plain process restart — the present
  `regenerate_master_id` fires only when the cursor exceeds the node's own
  sequence, so it serves as neither;
* whether the applier's exclusive window (§3.8) needs a cap below the response
  cap to bound write latency on a busy master;
* how `needs_rebuild` meets the operator's existing demote/hold/reseat path —
  SAF-10c's subject.
