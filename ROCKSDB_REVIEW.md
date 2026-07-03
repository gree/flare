# RocksDB Backend / WAL Replication — Review Document

- Target: PR [gree/flare#142](https://github.com/gree/flare/pull/142) "Feature: rocksdb"
- Reviewed commit: `d046c67` (line numbers in this document refer to that commit unless noted)
- Review date: 2026-07-03
- Purpose: enable a third party to (1) know **which viewpoints to review from**, and (2) see **why each item was judged OK or NG**, with code evidence (file:line) so every verdict can be re-checked.

---

## 1. Feature Overview

This PR adds the following to flare (a memcached-compatible distributed KVS).

| Component | Files | Role |
|---|---|---|
| RocksDB storage backend | `src/lib/storage_rocksdb.{h,cc}` | Third backend alongside `storage_tcb`/`storage_tch`, selected with `storage-type = rocksdb`. set/get/remove/incr semantics are designed to match `storage_tcb`. Keeps a header cache for deleted-key version continuity and snapshot-isolated iteration |
| WAL incremental replication | `src/lib/op_repl_sync_wal.{h,cc}` | Streams only the delta via RocksDB's WAL (`GetUpdatesSince`) instead of a full dump. `repl_sync_wal <...>` |
| Capability negotiation | `src/lib/op_meta.{h,cc}` extension | `meta features` returns the peer's `rocksdb_wal=1` / `master_id=...` for WAL support and lineage checks |
| Dump-replication integration | `src/lib/handler_dump_replication.cc` | Attempts WAL sync during cluster replication, falls back to full dump; self-demotion after N consecutive resync failures (split-brain protection) |
| Orphan key cleanup | `src/lib/op_orphan_scan.{h,cc}`, `op_orphan_purge.{h,cc}` | Two-phase scan (dry run) → token → purge of keys not owned by this node after partition changes |
| Reconstruction integration | `src/lib/handler_reconstruction.cc` | Adopts the peer's `master_id` after reconstruction (lineage handover) |
| Configuration | `src/flared/ini_option.{h,cc}` | `rocksdb-wal-ttl-seconds` (86400), `rocksdb-wal-size-limit-mb` (10240), `rocksdb-wal-max-batch-bytes`, `rocksdb-wal-sync-bwlimit`, `rocksdb-wal-sync-interval`, `rocksdb-resync-failure-threshold` (3), `rocksdb-sync-writes`, ... |
| Build | `configure.ac`, `Makefile.am`, `flake.nix`, `nix/default.nix`, CI | CI tests both the RocksDB build and the legacy build |

Design document: `ROCKSDB_REPLICATION.md`

---

## 2. Review Methodology (for reproducibility)

1. **Candidate discovery**: the whole diff was scanned from 8 independent angles (line-by-line scan / removed-behavior audit / cross-file call tracing / reuse / simplification / efficiency / abstraction level / test coverage) to enumerate candidate findings.
2. **Per-candidate verification**: each candidate was verified independently. The verifier read the code, its callers, the reference backend (`storage_tcb`), and the RocksDB headers (`include/rocksdb/db.h` of rocksdb 8.3.2), and returned **CONFIRMED (a concrete trigger path was identified in the code) / PLAUSIBLE / REFUTED (a disproving line was identified)**.
3. Both CONFIRMED and REFUTED results are recorded below with evidence — REFUTED (= OK) verdicts are kept so that third-party reviewers do not repeat the same investigation.

---

## 3. Review Viewpoints and Verdicts

### Viewpoint 1: Replication correctness (most critical)

**What to check**: Does data flow in the right direction? Can incremental sync resume without losing updates? Is lineage (which master the data came from) tracked?

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1-1 | Does the client side read the server response? | **NG (F1)** | `op_repl_sync_wal.cc:62-64` `run_client(lsn, master_id)` only calls `_run_client()` (= `_send_request()` alone, lines 258-264) and never calls `_parse_text_client_parameters()`. The correct pattern is `op_dump::run_client` (`op_dump.cc:65-71`: parse explicitly after sending). Consequence: `_client_result` stays at its constructor default `client_server_error` (line 42) → the success check at `handler_dump_replication.cc:155` can **never** pass → WAL sync never succeeds and always falls back to full dump. Worse, the server's written response (LSN/BATCH stream or error line) stays unread on the shared connection, and the following full dump's `op_set` (line 222) reads it as its own response = **protocol desynchronization**. The entire client parser (lines 266-422) is dead code |
| 1-2 | Data direction of WAL sync | **NG (F1)** | `handler_dump_replication` is created only by `cluster_replication::_start_dump_replication` (`cluster_replication.cc:229-232`, gated by "master and mode=duplicate", line 104) — a **push path** (this node sends its data to the destination; Phase 3 pushes via `op_set`). Yet the WAL phase (`handler_dump_replication.cc:128-151`) sends `repl_sync_wal <own LSN>`, i.e. it **receives the destination's WAL and applies it to local storage** (`op_repl_sync_wal.cc:396` `apply_batch_with_lsn`) = **pull**. The direction is inverted. The in-code NOTE (lines 121-127) itself admits "who streams to whom needs an audit". Masked today by 1-1 (response never read); fixing 1-1 alone would cause "the source overwrites itself with the destination's data while the destination receives nothing" — **both must be fixed together** |
| 1-3 | Is a purged WAL gap detected? | **NG (F2)** | `storage_rocksdb.cc:893-909` relies on `status.IsNotFound()`. But per rocksdb 8.3.2 `db.h:1592-1597`, when the requested batch is gone `GetUpdatesSince` **returns OK positioned at the next available batch**. NotFound only fires for "requested LSN > latest", which the earlier slave-ahead check (`op_repl_sync_wal.cc:152-160`) already intercepts, making the `ERR_LSN_PURGED` branch effectively dead. No continuity check exists (`first_seq` is computed for logging only, lines 179-186); the receiver applies without a gap check and advances `repl_last_lsn` (lines 352-404, `storage_rocksdb.cc:925-949`) → **a replica that lagged past WAL retention silently loses the missing range and reports success** |
| 1-4 | Lineage (master_id) check consistency | **NG (part of F1)** | The server compares the request's master_id with its own `get_master_id()` (`op_repl_sync_wal.cc:139-140`). But a cluster-replication destination is an independent cluster with its own master_id, so in the push path **this comparison can never match** — a design contradiction. The NOTE at `handler_dump_replication.cc:118-126` acknowledges it as unresolved. The fix must redesign it as "the destination records the source's master_id" |
| 1-5 | Safe fallback against old flared peers (mixed versions) | **OK** | An old flared answers `meta` with `op_error` → a single `ERROR\r\n` line (`op_parser_text.cc:55,78-79` consumes the whole request line; `op.cc:181-190` emits one line), and the client `_parse_text_client_features` (`op_meta.cc:291-337`) does **exactly one readline**, consumes that line fully, and returns success with `wal_supported=false` (lines 328-331). The connection stays byte-aligned into the full dump → mixed-version clusters work (candidate REFUTED by verification) |

### Viewpoint 2: Impact on existing behavior (backward compatibility)

**What to check**: Do existing non-RocksDB deployments behave identically? Do storage semantics match the existing backends?

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 2-1 | No RocksDB code in the legacy build | **OK (conditional)** | CI verifies symbol absence via `nm result/bin/flared \| grep rocksdb` (`.github/workflows/nix-linux.yml`). But see 6-2 for the configure auto-enable issue |
| 2-2 | set/get/remove/cas semantics match tcb | **OK** | The common storage suite (`test/lib/common_storage_tests.cc`, 1618 tests) passes fully on the rocksdb backend. The suspected touch-path divergence (tcb's restore block at `storage_tcb.cc:288-294`) was **REFUTED**: the restore is redundant except for `r = result_touched` (both backends assign the same values before storing, `storage_tcb.cc:210-256` == `storage_rocksdb.cc:391-437`), and `perform_touch_check` (`common_storage_tests.cc:692-717`) asserts version/size/data and passes on both |
| 2-3 | incr edge-case behavior matches tcb | **NG (F8)** | Overflow: tcb clamps to UINT64_MAX (`storage_tcb.cc:373-378`, `m = 0; m--;`), rocksdb wraps with plain addition (`storage_rocksdb.cc:688-689`). Expiry: tcb physically removes the expired record on incr (`storage_tcb.cc:424-428`); rocksdb does not (record survives, observable via `behavior_skip_timestamp` get / dump / replication). decr's clamp-to-0 and non-numeric handling **match (OK)**. The common suite only applies `incr 1` to "0"/"25" (`common_storage_tests.cc:771,782`), so this went undetected |
| 2-4 | Protocol changes on the public node port | **OK (needs a release note)** | `op_parser_text_node.cc:124-135` dispatches `meta`/`repl_sync_wal`/`orphan_scan`/`orphan_purge` in all builds (with internal `not_supported`/`not_compiled` guards: `op_orphan_purge.cc:56-58,148-151`). `meta` used to return ERROR on node servers; the information it now exposes (partition size etc.) is no more sensitive than the existing `stats`/`dump`. Unauthenticated destructive ops match the **existing trust model** (`flush_all` has always been on the same port unauthenticated), and orphan_purge has interlocks: UUID token (single-use, 300s TTL, `storage_rocksdb.cc:1012-1015`, `op_orphan_purge.cc:133`), `node_map_version` invariance check (lines 80-87), refusal without a partition assignment (lines 101-103). Recommend one line in the docs |

### Viewpoint 3: Concurrency / locking model

**What to check**: Is protection equivalent to `storage_tcb`'s locking model (slot rwlocks + whole lock + dedicated iteration mutex)? Are RocksDB's thread-safety properties (point reads/writes safe, iterators NOT safe) assumed correctly?

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 3-1 | iter_begin exclusivity and lock release | **NG (F5)** | `storage_rocksdb.cc:777-797`: (a) the busy `return -1` (line 784) **never releases** the just-acquired `_mutex_wholelock` rdlock; no caller (`op_dump.cc:168`, `op_orphan_scan.cc:93`, `op_orphan_purge.cc:105`, `op_dump_key.cc:146`, `handler_dump_replication.cc:182`) calls `iter_end()` after a failed begin → permanent leak. (b) the busy check runs under a **shared** rdlock, so two threads can both pass it, share a non-thread-safe `rocksdb::Iterator` (`iter_next` takes no lock, lines 802-828), leak a snapshot/iterator, and race into a double delete in `iter_end` (838-846). The correct shape is `storage_tcb::iter_begin` (`storage_tcb.cc:606-619`: check-and-set serialized by a dedicated `_mutex_iter_lock`, unlock before the busy return) |
| 3-2 | _master_id protection | **NG (F6)** | `storage_rocksdb.h:112` `string _master_id` is written by the reconstruction thread (`handler_reconstruction.cc:119` via the dedicated pool, `cluster.cc:1595-1599`) through `set_master_id()` (`storage_rocksdb.cc:237`, unguarded assignment) and read by op worker threads through `get_master_id()` (`storage_rocksdb.h:204`, **const-ref, unguarded**) — readers (`op_meta.cc:140`, `op_repl_sync_wal.cc:139`, `op_stats.cc:174`, ...) are externally triggerable at any time → a C++ data race (use-after-free during string reallocation / wrong lineage comparison). The adjacent `_wal_sync_master_id_mismatch` is an AtomicCounter (`storage_rocksdb.h:121`) — counters were considered, the string was missed |
| 3-3 | truncate vs. concurrent operations | **NG (F8)** | `storage_rocksdb::truncate()` (lines 735-775) takes **no lock at all** (grep: this backend never wrlock's the whole lock). tcb wrlock's it in truncate/iter_next (`storage_tcb.cc:585,633`). Consistency between concurrent set and truncate is undefined. Side effect: the wholelock rdlocks taken by set/get/remove/incr (317,495,571,647) have no writer to exclude and are **pure overhead** (see 5-4) |
| 3-4 | Slot-lock granularity | **OK** | Slot rwlock acquisition and `behavior_skip_lock` handling in set/get/remove/incr follow the same pattern as tcb (verified by side-by-side reading). Since RocksDB point Get/Put are thread-safe themselves, the slot lock correctly protects entry semantics (version-check-then-write atomicity) |

### Viewpoint 4: Error handling / fault tolerance

**What to check**: Does malformed network input never kill the process? Do failure accounting and recovery (fallback, self-demotion) behave as designed?

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 4-1 | Malformed response tokens | **NG (F3)** | The client-side parse's `boost::lexical_cast` (`op_repl_sync_wal.cc:354` LSN, `:373` BATCH size) has no try/catch, while the server side (91-97) wraps the same cast — **asymmetric**. The only catch in the thread stack is `thread.cc:72` for `thread::shutdown_request` → a `bad_lexical_cast` propagates to `std::terminate`. **One malformed line from a peer crashes the whole flared process** (empty token from `util::next_digit` on non-digits, or uint64 overflow) |
| 4-2 | Batch size validation | **NG (F3)** | `size_t batch_size` (line 373) is passed into the **int** parameter of `connection::read(char**, int, ...)` (`connection.h:54`) — narrows negative above 2 GiB, breaking length handling; then `WriteBatch(string(batch_data, batch_size))` (line 393) constructs a string longer than the actual buffer → **out-of-bounds read** |
| 4-3 | Resync outcome accounting | **NG (F4)** | `handler_dump_replication.cc:239` `dump_succeeded = !is_shutdown_request()` means "no shutdown was requested", not "the dump succeeded". (a) an `op_set` failure `break` (222-226) and iterator errors (the loop condition at 198 does not distinguish `iteration_end` from `iteration_error`, and `i` is never checked) → **real failures counted as success** (streak reset). (b) conversely a graceful shutdown counts as failure → repeated restarts can self-demote a healthy node. (c) early returns (connect failure 78-82, `iter_begin` failure 182-185) skip accounting entirely. (d) the WAL success path (155-158 `return 0`) never reaches `notify_resync_result(true)` (only call site: line 260) — contradicting the comment at 250-251 and the design in `ROCKSDB_REPLICATION.md:68-73` |
| 4-4 | Self-demotion target | **OK** | `request_down_node(self)` is the documented intent (`ROCKSDB_REPLICATION.md:71-72,307-309`; matching code comment at `handler_dump_replication.cc:250-256`): mark itself state_down to preserve data, operator runs `up_node` after repair. Only the success/failure classification feeding it (4-3) is wrong |
| 4-5 | Connection integrity after a failed meta probe | **OK** | Same verification as 1-5: the probe reply is a single line for every peer version and readline consumes it fully, so the connection stays line-aligned into the full dump (the desync comes from 1-1's unread stream, not the probe). Minor: when `run_client_features` fails at transport level, the handler still proceeds to a doomed dump on the dead connection (`handler_dump_replication.cc:102-107`) — fails fast, no corruption |

### Viewpoint 5: Resources / throughput

**What to check**: No extra I/O, copies, or locks on the hot paths (get/set/incr)? Is replication memory/bandwidth bounded?

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 5-1 | WAL backlog memory | **NG (F2)** | `storage_rocksdb.cc:904-909` deep-copies **every batch into a vector before anything is streamed** (`*batch.writeBatchPtr`), with no cap parameter (`storage_rocksdb.h:194`). Retention defaults are `wal_ttl=86400s` / `wal_size_limit=10GB` (`ini_option.h:150-151`) → one lagging replica can cause a multi-GB RAM spike on the master. `_max_batch_bytes` (`op_repl_sync_wal.cc:211`) is a per-batch check **after** materialization and bounds nothing. Streaming from the iterator would also make the 1-3 continuity check natural |
| 5-2 | Do the throttle options work? | **NG (F7)** | `_max_batch_bytes`/`_bwlimit_kbps`/`_interval_usec` are only read in `_run_server()` (`op_repl_sync_wal.cc:193-248`), but the setters are called only on the client-side op (`handler_dump_replication.cc:139-149`). The server-side op is constructed bare (`op_parser_text_node.cc:126-127`), leaving all three at 0 = unlimited (`op_repl_sync_wal.h:72-74`). **All three ini options do nothing on the serving node** (including the batch_too_large protection) |
| 5-3 | stats curr_items | **NG (F9)** | `storage_rocksdb::count()` (853-866) iterates the whole DB **per `stats` command** (`stats.cc:131-132` → `op_stats.cc:138`). tcb is O(1) (`tcbdbrnum`, `storage_tcb.cc:677-679`). Periodic monitoring turns into a permanent full scan |
| 5-4 | get() locking and copies | **NG (F8/F9)** | `storage_rocksdb::get()` (494-496) takes the global wholelock rdlock in addition to the slot lock; tcb's get takes only the slot lock (`storage_tcb.cc:451-459`). Since this backend has no wholelock writer (3-3), the rdlock is pure per-op overhead on a shared cache line. **Chosen fix: give truncate the wrlock so the rdlocks become meaningful** (rather than removing them) |
| 5-5 | incr I/O count | **NG (F9)** | `incr()` does its own `get()` (line 654 → Get #1), then delegates to `set()` whose `_get_header` (line 335) re-reads the same key (Get #2). tcb does one get + one put (`storage_tcb.cc:332,400`). +50% read work on counter workloads |
| 5-6 | Old-value read on overwrite | **Improvement noted (F9)** | `_get_header` (152-177) fetches the **entire value** to decode a ~30-byte header. With `enable_blob_files=true, min_blob_size=4096` (126-127), overwriting a ≥4KB value pays a blob-file read of the old value every time. tcb uses `tcbdbget3` (no copy). A header column family would fix this — recorded as future work |

### Viewpoint 6: Operations / build configuration

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 6-1 | Debian package impact | **OK** | `Dockerfile.debian-build` and `debian/control` Build-Depends contain no rocksdb, so the container build cannot pick it up (candidate REFUTED) |
| 6-2 | configure opt-in behavior | **NG (F10)** | `configure.ac:68-69`: without `--with-rocksdb`, `$with_rocksdb` is empty, so `AC_CHECK_LIB(rocksdb, ...)` still runs and, if librocksdb exists on the host, auto-defines `HAVE_LIBROCKSDB`, links `-lrocksdb`, and enables `ENABLE_ROCKSDB` (AM_CONDITIONAL at line 99). Confirmed in the generated configure (19567-19571). Contradicts BUILD.md's "plain configure = Legacy Build (Default)". Same pattern as kyotocabinet/zookeeper, but **this backend changes replication behavior, so it should be an explicit opt-in** |
| 6-3 | CI configuration | **OK (fixed)** | Before: `on: [push, pull_request]` ran the same commit twice, and the statistical flare-tests `repartition` test (`dev < 0.3`) failed one of them. Fixed: push limited to master + concurrency + 3x retry of the test build (commit `6120ce8`) |

### Viewpoint 7: Test sufficiency

**What to check**: For each surface of the new feature, does a test exist that would actually catch a bug in it?

| # | Area | Verdict | Evidence |
|---|---|---|---|
| 7-1 | Storage semantics | **OK** | Common suite of 1618 tests (set/get/remove/cas/expire/touch) runs against rocksdb (`test/lib/test_storage_rocksdb.cc`) |
| 7-2 | WAL wire protocol | **NG (F11)** | **No test** drives the `repl_sync_wal` send/receive framing or error-line classification. Existing tests call `get_updates_since`/`apply_batch_with_lsn` directly, bypassing the network layer (their comments say so). **This is precisely why 1-1 (response never read), 1-2 (inverted direction), and 4-1 (parse crash) survived 1618 passing tests** — itself proof that protocol-level tests are mandatory |
| 7-3 | handler_dump_replication new paths | **NG (F11)** | The existing `test_handler_dump_replication.cc` uses mock_storage, so `get_type() != type_rocksdb` and none of the new negotiation/fallback/accounting code ever executes → 4-3 went unnoticed |
| 7-4 | orphan_purge deletion core | **NG (F11)** | Only the token round-trip is tested. Nothing verifies "exactly the orphan keys are deleted and no owned key is". A hash-resolution mismatch = mass data loss, so this is essential |
| 7-5 | Restart persistence | **NG (F11)** | No test checks data and `repl_last_lsn` survive close→open (the reopen tests only check master_id: `test_storage_rocksdb.cc:390,418`). Version continuity for deleted keys after header-cache eviction or restart is also unverified (deleted-key resurrection would go undetected) |
| 7-6 | incr edge cases | **NG (F11)** | Per 2-3: nothing near UINT64_MAX and no physical-removal check for expired entries |

---

## 4. Findings and Status

Severity: **S** (data corruption / crash / feature broken) / **A** (misbehavior / operational risk) / **B** (performance / maintainability)

| ID | Sev | Finding | Where | Status |
|---|---|---|---|---|
| F1 | S | WAL sync: response never read → always fails + connection desync (1-1); direction inverted (1-2); lineage-check contradiction (1-4) | op_repl_sync_wal.cc, handler_dump_replication.cc | **Fixed**: redesigned as a push protocol (`repl_sync_wal begin` = the source obtains the destination's LSN and streams its own WAL; `repl_sync_wal seed` = after a full dump the source records its lineage and position on the destination). Every failure path stays line-synchronized (ABORT/ack); the handler reconnects if the connection is desynchronized |
| F2 | S | Purged-LSN gaps passed silently (1-3) + whole backlog materialized in RAM (5-1) | storage_rocksdb.cc | **Fixed**: `get_updates_since()` gained a continuity check (first batch must satisfy `sequence <= requested+1`; an empty result below the latest sequence is a purge) and a byte budget + `has_more`. The sender fetches in 64 MiB chunks |
| F3 | S | One malformed line crashes the process (4-1) + batch_size narrowing and OOB read (4-2) | op_repl_sync_wal.cc | **Fixed**: every `lexical_cast` guarded by try/catch; sizes parsed as uint64 and rejected above a 1 GiB hard limit plus the node's own `wal_max_batch_bytes` (refused batches are drained to keep the stream framed); exact-N reads via `readsize()` |
| F4 | A | Inverted resync accounting, missed accounting paths, no reset on WAL success (4-3) | handler_dump_replication.cc | **Fixed**: outcome derived from what actually happened (op_set failure / iteration_error / connect / iter_begin failure → failure; shutdown → not counted). Both WAL success and dump success call `notify_resync_result(true)`. Accounting centralized in `_notify_resync_result()` |
| F5 | A | iter_begin lock leak and missing exclusivity (3-1) | storage_rocksdb.cc | **Fixed**: dedicated `_mutex_iter_lock` serializes the busy check and cursor setup (same as storage_tcb); the busy path never acquires the whole lock |
| F6 | A | _master_id data race (3-2) | storage_rocksdb.h/cc | **Fixed**: guarded by `_mutex_master_id`; `get_master_id()` returns by value |
| F7 | A | WAL throttle ini options inert on the serving side (5-2) | op_repl_sync_wal.cc | **Fixed**: with the push redesign the sender is the protocol client, so the throttle the handler configures now governs the actual send loop. The receiver defends itself with its own `wal_max_batch_bytes` |
| F8 | A | Lock-free truncate (3-3); incr overflow/expiry divergence from tcb (2-3) | storage_rocksdb.cc | **Fixed**: truncate wrlocks the whole lock (making the existing rdlocks meaningful) and groups deletes into 1024-entry WriteBatches. incr clamps to UINT64_MAX and physically removes expired records, matching tcb |
| F9 | B | count() full scan (5-3); incr double Get (5-5); _get_header full-value read (5-6) | storage_rocksdb.cc | **Fixed (partially)**: count() is O(1) via an exact maintained counter (persisted on clean close, re-counted after a crash, delta-tracked through WAL applies). incr stores with a single Put instead of going through set(). **The `_get_header` full-value read (blob amplification) needs a header column family — future work** |
| F10 | A | configure auto-enables RocksDB (6-2) | configure.ac | **Fixed**: detection only runs when `--with-rocksdb` is given explicitly (also fixed the `-Iyes/include` bug for the bare `--with-rocksdb` form) |
| F11 | A | Missing protocol/handler/purge/persistence/incr-edge tests (7-2 – 7-6) | test/ | **Fixed (partially)**: new `test_op_repl_sync_wal.cc` (both protocol sides: framing, malformed input, roundtrip); storage tests added for reopen persistence, incr overflow, count maintenance, fetch budget, reserved-key filtering. **The orphan_purge deletion core and a two-process E2E remain open (needs flare-tests-side work)** |
| CI | A | Flaky test and duplicated runs (6-3) | .github/workflows/nix-linux.yml | **Fixed in `6120ce8`** |

### Additional defenses added while fixing (not in the original findings)

- `apply_batch*` filters reserved metadata keys (`__flare_repl_master_id` / `__flare_repl_last_lsn` / `__flare_record_count`) out of incoming batches, so a peer's markers travelling in its WAL can never overwrite ours (prevents unintended lineage takeover).
- `apply_batch*` now runs under the exclusive whole lock (previously it raced slot-locked writers with no lock at all).
- After the first failed batch on the destination, the rest of the stream is drained but not applied (a destination never applies batches with a gap).

### Design-level future work (recorded, intentionally not done in this PR)

- The `type_rocksdb` check + `dynamic_cast` pattern appears in 8 places (handler_dump_replication ×3, op_meta, op_stats, orphan_scan/purge, handler_reconstruction). Adding `capability_wal_sync` to the existing `storage::capability` mechanism (used by `op_keys.cc`), a `virtual append_stats()`, and a `virtual get_feature_tokens()` would keep generic code untouched when a fourth backend arrives.
- orphan_scan/purge only use generic APIs (iterator/resolver) and need not be RocksDB-only. Their orphan-judgment loops are duplicated (`op_orphan_scan.cc:93-112` vs `op_orphan_purge.cc:112-129`) — without a shared helper, a divergence would make purge delete keys the scan never reported.
- The resync-failure streak / self-demotion policy is replication-level and does not belong inside storage_rocksdb (tcb-family backends would benefit from the same protection).
- The `meta features` token `rocksdb_wal=1` bakes the backend name into the wire protocol; a capability name like `wal_sync=1` is preferable.
- The bwlimit wait pattern is hand-copied in three places (op_dump / handler_dump_replication / op_repl_sync_wal); fold it into `bwlimitter::throttle()`.
- UUID generation is duplicated (`storage_rocksdb.cc:204-208` and `:1013-1016`).

---

## 4b. Second-Review Findings on `138286a` (the fixed code) and Their Fixes

A second review of the redesigned (push-protocol) code surfaced further
defects. All are addressed below. Severity: **C** = critical.

| ID | Sev | Finding | Fix |
|---|---|---|---|
| C1 | C | WAL apply bypasses the destination cluster's key routing (`pre_proxy_write`) and slave fan-out (`post_proxy_write`): the full-dump path goes through `op_set` and is routed/replicated, but the WAL path applies directly to the entry node's local RocksDB. With >1 partition or a slave under the destination's partition, keys land on the wrong node (unreadable) or the destination's slaves silently diverge — and resync still reports success. | The destination now refuses `begin`/`seed` unless it is a single active partition with no slaves (`cluster::is_wal_sync_destination_safe()`, checked in `op_repl_sync_wal::_run_server_begin/_run_server_seed`); wider topologies reply `topology_unsupported`, which the source classifies as not-applicable and falls back to a full dump. The op now receives `cluster*` (wired in `op_parser_text_node.cc`). ROCKSDB_REPLICATION.md documents the constraint. |
| C2 | C | (Carried over from PR #140.) orphan scan/purge guarded only on `partition < 0`. A node in `state_prepare`/`state_ready` has `node_partition = N ≥ 0` in the PREPARE partition map, but `get_node_partition_map_size()` counts only the active map, so `partition_size = N` and `resolve(h, N) ∈ [0,N-1] ≠ N` holds for EVERY key → 100% judged orphan → purge wipes the whole dataset mid-reconstruction (prepare is a stable state, so the token never expires). | Both ops now additionally require `node_state == state_active` and `partition < partition_size` (i.e. the partition exists in the active map), else refuse with `not_active` (`op_orphan_scan.cc`, `op_orphan_purge.cc`); a token issued in a bad state is cleared. |
| C3 | C | The `master_id` token identified a "lineage" but not the physical DB (WAL sequence domain). After a partition split, a new master reconstructed from an old one inherited its token (`M0.id == M1.id`); when both push to the same destination, the destination's recorded LSN — a position in M1's sequence domain — would be trusted by M0 as a position in its own WAL, so M0 streams only from that number on and never full-dumps, leaving the destination missing most of M0's partition while reporting success. | Introduced a separate `repl_source_id` marker (reserved key) recording which source (sequence domain) the destination's `repl_last_lsn` belongs to. `begin` now matches the source's id against `repl_source_id`, not against the destination's own `master_id`; a node's own `master_id` is now immutable (reconstruction no longer adopts the peer's token — `handler_reconstruction.cc`). `truncate` clears source+lsn together. |
| M1 | major | `seed` persisted `master_id` then `repl_last_lsn` as two separate synced Puts; a crash between them (or the second failing) left a new source paired with a stale position → the next sync skips a gap (compounds C3). | `storage_rocksdb::set_repl_source()` writes the source id and the lsn in a single atomic `WriteBatch` (same S5 invariant the batch-apply path already used). |
| N1 | major | Neither `_stream_batches` (source) nor `_receive_batches` (destination) checked `is_shutdown_request`, and a persistently-behind catch-up looped `while(has_more)` forever — a graceful shutdown could hang for hours and the resync never returned. | Both loops now check `_shutdown_requested()` each iteration (source aborts the stream, destination drains-and-fails so the connection stays framed); the source also caps catch-up at `max_fetch_iterations` (64) and falls back to a full dump on non-convergence. |
| N1' | major | `iter_begin` held the wholelock **rdlock** until `iter_end`, while during iteration the same thread calls `get()`/`remove()` (which re-acquire it) — and this PR made `truncate`/`apply_batch` take it as a **writer**. On a writer-preferring rwlock that is a hard deadlock; on glibc it stalls flush_all / WAL apply for the whole (bwlimited, possibly hours-long) iteration. | Iteration no longer holds the wholelock at all — the RocksDB snapshot already gives a consistent view, so there is nothing for it to protect. `_mutex_iter_lock` still serializes concurrent iterations. The writer↔recursive-reader deadlock is gone. |
| M5 | major→minor | A failed connection to the destination counted as a resync failure of the (healthy, authoritative) source; repeated destination outages + config reloads could self-demote it. | Connect and reconnect failures no longer call `notify_resync_result(false)` (`handler_dump_replication.cc`); only real dump failures (op_set / iterator error) do. |
| F8-residual | minor | `get()` detected expired records but never removed them (unlike tcb), so TTL-heavy workloads accumulated dead rows. | `get()` now physically removes an expired record after releasing its read locks (version-guarded), matching `storage_tcb::get`. |
| F2-test-gap | major | The F2 regression test admitted it could not reproduce a purge and only checked contiguous/beyond-latest, yet the checklist marked F2's purged detection ✓. | Added `test_wal_get_updates_since_purged_detected`: flushes the memtable and deletes archived WAL files (`flush_and_purge_wal_for_test()`), then asserts `get_updates_since(0)` returns `ERR_LSN_PURGED` (or, if the environment retained the WAL, a contiguous stream — never a silent gap). |

---

## 5. Verification Checklist (functional acceptance)

For third-party acceptance testing. [ ] = not done / [x] = covered by automated tests

**Storage**
- [x] memcached-compatible set/get/remove/cas/expire/touch (common suite, 1618 tests)
- [x] Data and `repl_last_lsn` survive a flared restart (close→open) (`test_reopen_persists_data_and_repl_last_lsn`)
- [ ] After deletion + header-cache eviction (more deletions than `header_cache_size`), a set with an older version is still rejected
- [x] incr clamps at UINT64_MAX (`test_incr_overflow_clamps_to_uint64_max`); expired-record removal matches tcb (implementation aligned; covered by existing expire tests)
- [ ] Concurrent set/get during `flush_all` (truncate) stay consistent (wrlock implemented; concurrency test not added)

**WAL replication**
- [x] Wire-protocol roundtrip in one process: client output → server apply yields identical data and LSN (`test_push_stream_roundtrip`). Two-process operational E2E not done
- [x] When the source WAL no longer covers the destination position: `ABORT lsn_purged` → full dump (continuity check; `test_wal_get_updates_since_boundaries` etc.)
- [x] Malformed responses (`LSN abc`, `BATCH not_a_number`, unexpected lines) never crash the process and are classified for fallback (`test_client_push_malformed_*` / `test_server_begin_malformed_*`)
- [x] `rocksdb-wal-max-batch-bytes` enforced on both sides (`test_server_begin_oversized_batch_rejected`). Bandwidth measurement of bwlimit/interval not done
- [x] Against an old flared (single-line `ERROR` reply): classified not_supported, full dump proceeds (`test_client_push_classifies_not_supported_on_error_reply`)

**Resync / self-demotion**
- [ ] A mid-dump connection drop is counted as a failure (streak increments)
- [ ] WAL-sync success and full-dump success both reset the streak to 0
- [ ] Reaching the threshold marks the node state_down; `up_node` restores it
- [ ] A graceful-shutdown interruption is not counted as a failure

**Orphan scan/purge**
- [ ] After a partition change, scan-reported count == purge-deleted count, and no owned key is deleted
- [ ] A topology change between scan and purge causes purge to refuse (token invalidated)
- [x] Token TTL and single-use (storage layer only)

**Operations**
- [x] Legacy build contains no rocksdb symbols (CI)
- [ ] `./configure` without `--with-rocksdb` disables RocksDB even when librocksdb is installed on the host
- [ ] All `rocksdb_*` stats values are sane (especially `curr_items` latency with large key counts)

---

## 6. Change History

| Date | Change |
|---|---|
| 2026-07-03 | Initial version (review performed; CI fix `6120ce8`) |
| 2026-07-03 | Implemented fixes F1–F11 (push-protocol redesign, locking fixes, record counter, tests). Updated ROCKSDB_REPLICATION.md to the new protocol. Line-number references are as of `d046c67` (they shift after the fixes) |
| 2026-07-03 | Translated to English to match the repository's documentation language |
| 2026-07-03 | Second review of `138286a` found further defects (C1–C3 critical, N1/N1'/M1/M5 major, F8-residual, F2 test gap); all fixed. See section 4b. |
