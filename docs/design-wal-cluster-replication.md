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

- **(A) v2 pulls from v1 (preferred).** Reuse the existing pull `run_client`
  semantics but invert roles: the operator tells each v2 master to run a
  WAL-sync *client* against the corresponding v1 master as source. This reuses
  the battle-tested reconstruction client path almost verbatim; the only new
  thing is "source is a remote cluster's node" instead of the local master.
  The `master_id`/`last_lsn` seeding (§5.3) makes the existing gate fire.
- **(B) v1 pushes to v2 (new server-initiated stream).** More new C++, more
  risk. Only if (A) is impossible given the migration control flow (v1 is the
  one holding `spec.clusterReplication`).

Recommendation: **(A)**. It keeps cluster replication reusing the reconstruction
WAL path rather than inventing a second WAL transport. The cluster-replication
feature's role becomes orchestration + live forwarding; the bulk WAL copy is
"each v2 node reconstructs from its v1 peer."

### 5.3 Cross-cluster lineage seeding

For the WAL gate to fire, each v2 node must adopt its v1 peer's identity:

- v2-node(partition i) calls `set_master_id(v1_peer.master_id)` and seeds
  `repl_last_lsn` to v1_peer's starting LSN — analogous to the post-dump seeding
  reconstruction already does, but done cross-cluster per corresponding node.
- This MUST be a **migration-only, explicitly-flagged path**, separate from
  normal reconstruction, so a stray same-`master_id` can never make the #14
  truncate gate or the WAL gate misfire during ordinary operation. Concretely:
  a dedicated op/flag ("adopt lineage for migration") rather than reusing the
  reconstruction seeding, and it is only ever issued by the operator during a
  gated same-topology migration.

### 5.4 Live writes during the WAL window (Dumping→Forwarding)

The existing dump+forward model is idempotent (forwarded `set`s can double-apply
harmlessly). WAL batches replayed verbatim + concurrent forwarded sets need
**explicit LSN fencing** at the handoff: the consumer records the last WAL LSN
applied, and forwarding for that partition begins only from writes after that
cursor. Design the handoff so a key written during the WAL window is either in
the WAL stream or in the forward stream, never lost, and double-apply stays
harmless (sets remain idempotent; deletes need ordering care).

### 5.5 WAL-retention coordination

`GetUpdatesSince` only works while the WAL segments since `last_lsn` still
exist. For a large/slow migration v1 must retain WAL long enough for v2 to
consume it; if v1 purges faster than v2 consumes, the stream breaks →
**automatic fall back to full dump** for that partition (never silently stall).
The operator should raise v1's WAL retention (`walTtl`/`walSize`) for the
duration of the migration and restore it after.

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

## 8. Recommended sequencing

1. **First** close the verification hole: get the existing full-dump cluster
   replication actually exercised end-to-end on a real image (today the E2E
   skips when 0 keys land). Without this, no WAL path can be trusted.
2. Implement §5.1 gate + option (A) transport + §5.3 migration-only seeding.
3. Add the same-count WAL E2E and the different-count-falls-back-to-dump
   negative E2E.
4. Ship behind an explicit opt-in (`spec.clusterReplication.mode: "wal"` or a
   `wal: true` sub-flag), defaulting off, documented as same-topology-only.

## 9. Verdict

Feasible and worthwhile for same-size migrations; **not** a shrink accelerator.
The engineering is dominated by safety plumbing (fail-closed gate, migration-only
lineage seeding, LSN-fenced handoff, retention coordination), not by the WAL copy
itself — which is why this is a design doc first. Given the payoff is limited to
same-count migrations, prioritize below closing the cluster-replication
verification hole (§8.1), which benefits every migration path.
