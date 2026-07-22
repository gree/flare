# Design: WAL-based cluster replication for same-topology migration

Status: DRAFT (design only — not implemented)
Author: flare-operator work stream
Scope: `src/lib/cluster_replication.*`, `src/lib/handler_dump_replication.*`,
`src/lib/op_repl_sync_wal.*`, `src/lib/storage_rocksdb.*`

## 1. Motivation

Cluster replication (Blue/Green migration via `spec.clusterReplication`) today
does a **full key-space dump** for the initial bulk copy: `handler_dump_replication`
scans every key with `iter_begin/iter_next`, filters to this node's partition,
and ships each surviving key as a per-key `op_set` to the destination cluster.
For a large dataset this is slow and I/O-heavy — it re-reads and re-hashes the
entire keyspace even when v2 is byte-for-byte able to consume v1's RocksDB WAL.

Intra-cluster reconstruction already solved the "copy a lot of data fast"
problem with a **WAL-first incremental path** (RocksDB `GetUpdatesSince` →
`op_repl_sync_wal`). The goal of this design is to reuse that machinery for
cluster replication **when it is provably safe** — i.e. when v1 and v2 have the
**same partition/master count** — and fall back to the existing full dump
otherwise.

### Non-goal / scope boundary (read this first)

WAL replication is **only** applicable when v1 and v2 have an identical
partition layout with a 1:1 master correspondence. It **cannot** help the
partition-**shrink** case (N→M masters, M<N) — that is the primary use case in
[RUNBOOK.md#shrink](RUNBOOK.md#shrink), and it necessarily re-hashes keys into a
different layout, which the WAL path cannot do (see §3). So this feature speeds
up **same-size migrations only**: version upgrades, hardware/nodepool
replacement, zone/subnet moves, storage-class changes. If your migration
changes the master count, this design does nothing for you — use the dump path.

## 2. Background: how flare's WAL/LSN actually work

Established by code reading (cite when implementing):

- **WAL/LSN is per-NODE (per RocksDB instance), not per-partition.**
  `get_latest_sequence_number` → `rocksdb::DB::GetLatestSequenceNumber`;
  `get_updates_since` → `rocksdb::DB::GetUpdatesSince`
  (`src/lib/storage_rocksdb.cc`). There is no per-partition WAL stream — the LSN
  is the sequence number of the whole DB on that node.
- **WAL batches apply VERBATIM.** `apply_batch_with_lsn` copies the incoming
  `WriteBatch`, appends the LSN marker, and `Write()`s it as-is — **no per-key
  re-hash, no partition filter** (`src/lib/storage_rocksdb.cc`). Contrast the
  dump path, which filters by partition per key. A WAL stream therefore
  reproduces the source node's key set byte-for-byte on the consumer.
- **`master_id` is a per-DB UUID.** Generated on first open, or adopted from
  one's master during reconstruction (`storage_rocksdb.cc`,
  `handler_reconstruction.cc`). The WAL server rejects any client whose
  `master_id` differs (`op_repl_sync_wal.cc` → `master_id_mismatch`), and the
  reconstruction client only takes the WAL path when
  `last_lsn>0 && peer_master_id == local_master_id`.

## 3. Why "same master count" is the hard precondition

Because batches apply verbatim:

- **Different partition counts → WAL is unsound.** Keys that belong on
  v2-node-A under v2's hashing would be written wherever the v1 source node's
  batch says — i.e. onto the wrong v2 node. The re-hash the dump path gets for
  free (per-key `set`) does not happen for WAL. **Never attempt WAL here.**
- **Same partition count with 1:1 node correspondence → WAL is sound.** If each
  v2 master consumes exactly the matching v1 master's whole-DB WAL, verbatim
  keys land exactly where v2's identical hashing would put them.

Note the operative reason is **verbatim application (no re-hash)**, not "LSN
streams don't line up." LSNs are per-node cursors and never line up across
clusters anyway; the consumer records the source's LSN as an opaque cursor, so
misalignment is a non-issue. Do not design around LSN alignment; design around
the verbatim/1:1 property.

> **Review correction — "1:1 master WAL = clean v2 partition" is FALSE without a
> precondition.** A node's RocksDB can hold **orphan keys outside its own
> partition** (leftovers from a prior assignment — that is what `orphan_scan`/
> `orphan_purge` exist for, `op_orphan_scan.h:19`, and why truncate clears them,
> `handler_reconstruction.cc:159`). The **dump path filters orphans out**
> (`handler_dump_replication.cc:200-208`: `resolve(...) != partition → continue`).
> The **WAL path replays them verbatim** onto v2, planting keys that don't
> belong to v2's partition (later servable/resurfacing). So byte-for-byte
> reproduction copies exactly what the dump path deliberately drops.
> **Precondition:** run `orphan_purge` on every v1 node before a WAL migration,
> or the 1:1-clean premise does not hold.
>
> **Review correction — RocksDB version skew.** WAL is `rocksdb::WriteBatch`
> bytes replayed verbatim. The whole premise (§1) includes *version upgrades* —
> exactly when v1 and v2 may run different RocksDB builds. WriteBatch /
> column-family / format compatibility across RocksDB versions is a **hard
> correctness precondition** for verbatim replay and must be asserted (equal
> RocksDB format) before choosing the WAL path; otherwise fall back to dump,
> which is format-independent (per-key ops).

## 4. Current code state (what exists, what's inert)

- `cluster_replication.cc` itself references only `dump`/`dump_replication` — no
  `last_lsn`, `sync_wal`, or `wal`.
- The dump handler it spawns (`handler_dump_replication.cc`) **does** include a
  WAL branch: it probes peer features, reads `get_repl_last_lsn()` /
  `get_master_id()`, and calls `op_repl_sync_wal::run_client(...)`. **But this
  branch is effectively dead cross-cluster:**
  1. **Direction bug.** Reconstruction is *pull*-based (`run_client` reads a
     stream and applies it to the local DB). Cluster replication needs *push*
     (v1 → v2). As written the dump handler reuses the pull-oriented
     `run_client` against v1's *own* DB, which would pull v2's WAL into v1 — the
     opposite of what's needed. The author left an explicit note that "who
     streams to whom in push-mode replication need[s] to be reconciled."
  2. **Guaranteed `master_id` mismatch.** A freshly-built v2 has its own UUIDs;
     the dump handler blindly sends v1's own `master_id`, so the server-side
     gate rejects it and it falls straight through to full dump. It also only
     calls the 1-arg feature probe, so it never even fetches v2's
     `master_id`/`latest_lsn`.

So today: cluster replication always does the full dump (plus live per-key
forwarding). The WAL code is present but never fires cross-cluster.

## 5. Proposed design

### 5.1 Precondition gate (fail-closed)

WAL cluster replication is attempted **only** when ALL hold; otherwise fall back
to the existing full dump. The gate must be **fail-closed**: any doubt → dump.

1. `v1.partitions == v2.partitions` AND `v1.masterCount == v2.masterCount`
   (topology equality), verified by the operator from both FlareCluster specs,
   not inferred by flared.
2. A concrete **1:1 node/partition peer map** is supplied: each v1 master's
   dump-replication handler is pointed at the *corresponding* v2 master node
   (partition i on v1 → partition i on v2), not an arbitrary v2 proxy entry
   point.
3. Peer (v2 node) advertises WAL support via the 3-arg feature probe, and the
   operator has completed lineage seeding (§5.3).
4. v2 target partition is empty / freshly built (never overwrite a populated v2
   node with a verbatim stream).

The gate lives partly in the **operator** (topology equality, peer-map
construction — it has both specs and the pod lists) and partly in **flared**
(feature probe, lineage check). Encoding topology equality in the operator keeps
the dangerous verbatim decision under the component that actually knows both
cluster shapes.

### 5.2 Push-direction WAL transport

Add a push variant so v1 streams its WAL to the matching v2 node. Two options:

- **(A) v2 pulls from v1 (preferred).** The operator tells each v2 master to run
  a WAL-sync *client* against the corresponding v1 master as source.

  > **Review correction — do NOT describe this as "reuse `run_client` almost
  > verbatim."** The address-agnostic wire op `op_repl_sync_wal` (`_run_client`
  > writes `repl_sync_wal <lsn> <master_id>` on whatever connection it's handed,
  > `op_repl_sync_wal.cc:258-264,396`) **is** reusable. But the *reconstruction
  > handler* around it (`handler_reconstruction`) is saturated with
  > intra-cluster assumptions and is **not** reusable:
  > 1. Source address is resolved from the **local node map**
  >    (`cluster.cc:1768-1784` `from_node_key(master_node_key,…)`); a v1 node is
  >    not in v2's map — there is no entry point to point it at an arbitrary
  >    remote address.
  > 2. It is triggered by **role transitions** (`proxy→master`/`*→slave`,
  >    `cluster.cc:1722,1757`), not by operator command.
  > 3. `partition_size` is computed from **v2's own maps** (`cluster.cc:1723,
  >    1767,1774`) — meaningless cross-cluster.
  > 4. On success it runs **v2-internal activation** side effects
  >    (`notify_master_reconstruction`, `_activate_with_retry`,
  >    `set_activation_pending`, `handler_reconstruction.cc:277-298`) — a bulk
  >    copy must NOT flip the v2 node to active.
  > 5. The WAL gate is lineage-bound to the **local** master
  >    (`handler_reconstruction.cc:394-409`), which is exactly why §5.3 seeding
  >    is needed — proving the path is not verbatim-reusable.
  >
  > **Honest reusable unit = `op_repl_sync_wal` only.** The driver (source
  > selection, command triggering, partition sizing, activation suppression,
  > gate pre-seed) is all NEW code in the most bug-prone module. This narrows
  > (A)'s advantage over (B) considerably.
- **(B) v1 pushes to v2 (new server-initiated stream).** More new C++. Given the
  review shows (A) is also mostly new driver code, (B) is no longer clearly
  worse and should be re-weighed on its merits (v1 holds
  `spec.clusterReplication`, so a push driver lives where the migration state
  already is).

Recommendation: still lean **(A)** for reusing the *wire op* and keeping the
pull semantics that already handle LSN purge fallback — but budget for a new
cross-cluster driver either way; do not plan around "reconstruction reuse."

### 5.3 Cross-cluster lineage seeding

For the WAL gate to fire, the consuming side needs a lineage that matches the
source. The naïve approach — have each v2 node `set_master_id(v1_peer.master_id)`
+ seed `repl_last_lsn` — is **more dangerous and more permanent than a "flag" can
fix**, per the review:

> **Review correction — `master_id` adoption permanently FUSES the two clusters'
> lineage and defeats the primary cross-cluster WAL safety gate.** `master_id` is
> a durable per-DB UUID at `__flare_repl_master_id` (`storage_rocksdb.cc:200-266`).
> Once v2's master holds v1's UUID, that identity is permanent and **propagates
> into v2's own internal lineage**: v2's own slaves later adopt the master's
> `master_id` on reconstruction (`handler_reconstruction.cc:243-257`) — i.e.
> v1's UUID. Consequences:
> - v1 and v2 now share one `master_id` **forever**. The `master_id` gate — the
>   primary guard against cross-lineage WAL application
>   (`op_repl_sync_wal.cc:136-146`) — is defeated between the clusters. The only
>   remaining check is `lsn_ahead` (`:152-160`), and cross-cluster LSNs are
>   unrelated cursors — so a stray/misconfigured WAL sync between the clusters
>   can pass the identity gate and apply foreign WAL. This is the #14/#15 class
>   the design claims to avoid.
> - **Mid-adopt split inside v2**: if v2 slaves already reconstructed under v2's
>   original fresh `master_id` before the master adopts v1's, the next intra-v2
>   WAL sync trips `master_id_mismatch` → forced full dumps across v2's replicas
>   during the migration window.
>
> A "migration-only flag" controls how the value is written, not its persistent
> shared-identity effect. **Do not adopt v1's `master_id`.**

**Revised approach — separate cross-cluster cursor, keep the intra-cluster
`master_id` invariant intact.** Instead of overwriting `master_id`, add a
distinct migration cursor the WAL path consults *only* in cluster-replication
mode: `(source_cluster_id, source_lsn)` stored separately from
`__flare_repl_master_id`. The WAL gate in migration mode checks the source
cluster id (not the local `master_id`), so v2 keeps its own fresh `master_id`
for all intra-v2 replication. Alternatively/additionally, **regenerate a fresh
v2 `master_id` at cutover** so no fused identity outlives the migration. Either
way, v2's internal lineage must never be contaminated with v1's UUID.

### 5.4 Live writes during the WAL window (Dumping→Forwarding)

> **Review correction — a clean LSN fence is NOT expressible on today's
> mechanism.** The live-forward path carries **no LSN and no sequencing**
> relative to the bulk stream: `on_post_proxy_write` enqueues a
> `queue_proxy_write` at proxy time (`cluster_replication.cc:219-242`) that
> replays the op (set/**delete**/incr) against the destination with no RocksDB
> sequence number attached. Bulk copy runs on a **separate thread/connection**
> (`cluster_replication.cc:252-258`) and forwarding is started (`_started=true`)
> **before** the dump (`cluster_replication.cc:86-102`). With no cursor on the
> forward path, you cannot express "forward only writes after WAL LSN N."
>
> **Concrete race that exists TODAY** (and worsens with WAL): the dump reads
> from a `GetSnapshot()` (`storage_rocksdb.cc:837`). A key deleted *after* the
> snapshot has its delete forwarded live to v2, but the bulk stream later ships
> the snapshot's *old* value as `op_set` (`handler_dump_replication.cc:222`) →
> **resurrected key on v2**. Ordering across the two connections is
> unguaranteed. "Forwarded sets double-apply harmlessly" holds for sets only;
> deletes have no ordering primitive at all.

Therefore this is not a small handoff detail — it requires **new plumbing**,
one of:
- **Sequence the forward path**: stamp forwarded ops with the source RocksDB
  LSN so the consumer can drop any forwarded op older than the bulk cursor
  (and vice versa), or
- **Quiesce/drain at a fenced cutover**: pause writes (or drain the forward
  queue to a known LSN) at the Dumping→Forwarding boundary so the two streams
  never overlap for a given key.

Note this delete-resurrection race is a **pre-existing cluster-replication bug**
independent of WAL — worth filing/fixing regardless of this feature.

### 5.5 WAL-retention coordination

`GetUpdatesSince` only works while the WAL segments since `last_lsn` still
exist. For a large/slow migration v1 must retain WAL long enough for v2 to
consume it; if v1 purges faster than v2 consumes, the stream breaks →
**automatic fall back to full dump** for that partition (never silently stall).
The operator should raise v1's WAL retention (`walTtl`/`walSize`) for the
duration of the migration and restore it after.

Graceful-failure plumbing **is** confirmed to exist: purged segments return
`ERR_LSN_PURGED` (`storage_rocksdb.cc:944-951`) → `SERVER_ERROR lsn_purged`
(`op_repl_sync_wal.cc:166-170`) → client classifies `client_lsn_purged` → dump
fallback (`handler_reconstruction.cc:449-453`, `handler_dump_replication.cc:167-174`).

> **Review caveat — which dump?** The reconstruction fallback is the
> *intra-cluster* `op_dump` (partition-sized from v2's maps,
> `handler_reconstruction.cc:213-226`), NOT the *cluster-replication* dump
> (`handler_dump_replication`, partition-filtered). Cross-cluster, `op_dump`'s
> partition-size arithmetic is wrong. So "reuse the fallback" does not cleanly
> hold for the pull direction — per-partition dump fallback is **new operator
> wiring**, not free reuse.

## 6. Change surface (summary)

| Area | Change |
|------|--------|
| operator (Lean) | topology-equality gate; build 1:1 v1↔v2 peer map; drive per-partition WAL-migration op; raise/restore v1 WAL retention; fall-back-to-dump on any gate failure |
| `op_repl_sync_wal` / handler | 3-arg feature probe path for cluster replication; migration-flagged lineage adopt |
| `storage_rocksdb` | migration-only `set_master_id` + `repl_last_lsn` seeding entry point (distinct from reconstruction) |
| `cluster_replication` | orchestrate "v2 pulls WAL from v1 peer" for bulk phase; keep per-key forwarding for live phase; LSN-fenced handoff |
| tests | E2E: same-count WAL migration on a real (non-kind-skipped) image; negative test: different-count MUST fall back to dump and MUST NOT corrupt |

## 7. Safety / concerns (the reason this is DRAFT)

Common theme: **WAL has no safety net (verbatim, no re-hash) and this touches
the least-hardened path plus the exact invariants behind bugs #14/#15.**

1. **Verbatim = correctness cliff.** One wrong precondition (count mismatch,
   mis-wired peer map) → keys on the wrong v2 node → silent loss. Gate must be
   fail-closed; different-count must be impossible to enter, not merely
   discouraged.
2. **`master_id` seeding is #14/#15 territory.** Conflating two lineages under
   one `master_id` can make the truncate/WAL gates misfire. Mitigation:
   migration-only flagged path, never the normal reconstruction seeding.
3. **New push/pull wiring in the riskiest module.** cluster replication already
   had several bugs. Prefer option (A) to reuse the proven reconstruction
   client and minimize new C++.
4. **Live-write handoff.** LSN fencing between WAL and forward streams must be
   exact; deletes need ordering care (sets are idempotent, deletes are not).
5. **1:1 mapping fragile under failover.** If a v1 or v2 master fails over
   mid-migration, the peer map and LSN cursor shift. Handle master change during
   migration (re-seed / restart that partition's stream, or fall back to dump).
6. **Weaker verifiability.** Dump is per-key verifiable (and the shrink E2E now
   checks it — though it always skips in the kind image). WAL is harder to
   verify; the same-count WAL path needs a real-image E2E BEFORE it can be
   trusted, closing the current always-skip hole first.
7. **Payoff is scoped.** Speeds up same-size migration only; does nothing for
   shrink. Weigh implementation cost against that limited scope.

### 7b. Additional holes surfaced by adversarial review (ranked)

1. **`master_id` fusion (§5.3)** — highest risk; addressed by the revised
   separate-cursor / regenerate-at-cutover approach. Must NOT ship the naïve
   adopt.
2. **§5.4 fence not expressible** — forward path has no cursor; delete-vs-stale-
   set resurrection is a real, pre-existing race. Needs new sequencing or a
   quiesced cutover.
3. **Orphan keys (§3)** — WAL copies keys the dump drops; require `orphan_purge`
   precondition on v1.
4. **Option (A) is mostly new code (§5.2)** — only `op_repl_sync_wal` is reusable.
5. **Fallback-to-dump ambiguity (§5.5)** — pull-direction dump fallback is new.

### 7c. Design gaps the first draft missed entirely

- **No auth/TLS on the WAL transport.** `op_repl_sync_wal` is instantiated with
  zero authentication (`op_parser_text_node.cc:127-128`) — plaintext
  memcached-style protocol. Intra-cluster that assumes a trusted LAN;
  **cross-cluster the whole-DB WAL byte stream would cross a trust boundary in
  cleartext.** Must define the network path/port and transport security before
  any cross-cluster WAL is allowed.
- **How the operator learns each side's `master_id`/LSN.** The only read path is
  the 3-arg `meta` probe over the node port (`op_meta.h:60`). LSN is a moving
  target between probe and stream start; specify the query mechanism and its
  consistency (probe→start handoff).
- **v2's own internal replication during the migration** — must be analyzed so
  the adopt (or its replacement) never forces mismatches/full-dumps inside v2.
- **RocksDB version-skew** (see §3 correction) — equal-format precondition.
- **Failover during migration** — source selection is node-map-internal
  (`cluster.cc:1768-1784`) with no external re-point; a v1/v2 master failover
  mid-stream has no defined recovery under (A). Needs an explicit re-seed /
  restart-partition / fall-back-to-dump policy.

## 8. Recommended sequencing

1. **First** close the verification hole: get the existing full-dump cluster
   replication actually exercised end-to-end on a real image (today the E2E
   skips when 0 keys land). Without this, no WAL path can be trusted.
2. Implement §5.1 gate + option (A) transport + §5.3 migration-only seeding.
3. Add the same-count WAL E2E and the different-count-falls-back-to-dump
   negative E2E.
4. Ship behind an explicit opt-in (`spec.clusterReplication.mode: "wal"` or a
   `wal: true` sub-flag), defaulting off, documented as same-topology-only.

## 9. Verdict (post-review)

Feasible for same-size migrations, **not** a shrink accelerator — but the
adversarial review moved this from "moderate safety plumbing" to **"large, and
gated on solving two hard problems first"**:

- The one genuinely reusable piece is the wire op `op_repl_sync_wal`. Everything
  else (cross-cluster driver, source selection, activation suppression,
  per-partition dump fallback) is new code in the least-hardened module.
- The naïve `master_id` adoption is unshippable (permanent lineage fusion); a
  separate-cursor design is required and is itself non-trivial.
- The live-write handoff fence is **not expressible** on the current forward
  path and exposes a pre-existing delete-resurrection race.
- New preconditions the draft lacked: `orphan_purge` on v1, equal RocksDB
  format, cross-cluster transport security, failover-mid-migration policy.

**Recommendation:** keep this DRAFT parked. Do NOT start WAL cluster replication
until (a) the cluster-replication verification hole is closed (§8.1 — the
current dump path isn't even end-to-end tested), and (b) the pre-existing
delete-vs-dump resurrection race (§5.4) is fixed independently. The payoff
(same-count migrations only) does not justify the risk surface ahead of those
two. Two of the review's findings — the delete-resurrection race and the missing
end-to-end verification — are worth acting on **now** regardless of whether WAL
is ever built.
