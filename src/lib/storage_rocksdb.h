/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
/**
 *  storage_rocksdb.h
 *
 *  RocksDB storage backend with WAL replication support
 *
 *  $Id$
 */
#ifndef STORAGE_ROCKSDB_H
#define STORAGE_ROCKSDB_H

#ifdef HAVE_STDLIB_H
# include <stdlib.h>
#endif // HAVE_STDLIB_H

#ifdef HAVE_STDINT_H
# include <stdint.h>
#endif // HAVE_STDINT_H

#include <cstdio>
#include <map>
#include <rocksdb/db.h>
#include <rocksdb/options.h>
#include <rocksdb/table.h>
#include <rocksdb/cache.h>
#include <rocksdb/write_batch.h>
#include <rocksdb/slice.h>
#include <rocksdb/iterator.h>
#include <rocksdb/snapshot.h>
#include <rocksdb/transaction_log.h>

#include "storage.h"
#include "util.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *  storage_rocksdb class - RocksDB storage backend
 */
class storage_rocksdb : public storage {
public:
	// Error codes for WAL operations
	// Outcome of the COMMON APPLY RULE (design §3.3). Both delivery paths —
	// op-level forwarding and the WAL stream — go through it, so a change
	// that is not strictly newer than what the key already has is never
	// applied, whichever path carried it.
	enum apply_outcome {
		apply_applied = 0,			// written
		apply_skipped_superseded,	// the key already holds this or a newer change
		apply_refused_cursor,		// at or below the applied position: already decided
		apply_refused_session,		// different source history, or generations unavailable
		apply_refused_incarnation,
		apply_refused_stale_follower,	// D7: from a follower that was stopped (overlap after an async stop)	// issued against a copy this node no longer is
		apply_refused_gap,			// the batch does not continue the applied position: the history between is GONE (or was never served) — rebuild, not retry
		apply_error,				// storage failure; nothing was written
	};

	static const int ERR_LSN_PURGED       = -1;
	static const int ERR_LSN_INVALID      = -2;
	static const int ERR_LSN_AHEAD        = -3;  // slave's LSN > master's latest
	static const int ERR_MASTER_ID_MISMATCH = -4;

	// Reserved metadata keys (hidden from get/set/remove/iter/truncate).
	// Defined in the .cc so they link once across TUs.
	static const char* const kReplLastLsnKey;
	static const char* const kReplMasterIdKey;
	static const char* const kReplSourceEpochKey;
	// Why the current source epoch was minted: "new" (fresh DB), "promotion",
	// "bulk" (truncate/flush_all) or "inherited" (snapshot restore). Absent on
	// DBs written before the reason was recorded (read as unknown).
	static const char* const kReplSourceEpochReasonKey;
	static const char* const kBulkChainKey;
	static const char* const kBulkPendingKey;
	// Partition binding: "v1 partition=<p> partitions=<n> size=<s> hash=<a>
	// resolver=<t> hint=<h> virtual=<v>" — the partition and the routing
	// layout whose keys this copy holds. Travels inside every checkpoint.
	static const char* const kPartitionBindingKey;
	// "1" while a RESTORED copy has not been accepted as a master of the
	// partition its binding names (set at the open that consumed RESTORED).
	static const char* const kRestoredUnverifiedKey;
	static const size_t kBulkChainKeep = 8;
	static const char* const kReplIncarnationKey;
	static const char* const kReplRestoreDoneKey;
	static const char* const kReplRebuiltFromKey;
	// R3-D: the evidence of the STORED copy while a rebuild is in progress
	// (moved here, durably, when an attempt starts; never advertised)
	static const char* const kReplRebuiltFromSuspendedKey;
	// Copy retention (docs/design-copy-retention.md §2): the persistent
	// identity of THIS stored copy, "<uuid>:<generation>". A different copy
	// (swap, reset, quarantine, a staging copy) gets a new uuid; replacing the
	// content in place (truncate) bumps the generation. Mirrored in the copy's
	// directory as COPY_ID (read by the switch recovery before the DB opens).
	static const char* const kCopyIdKey;
	// design §6: in data_dir, written BEFORE a corrupt copy is moved aside
	static const char* const kQuarantineMarkerFile;

	// Return true if key is a reserved replication metadata key.
	static bool is_reserved_key(const string& key);

	// Orphan-key management support. A scan issues a confirmation
	// token and remembers just enough context (count, bytes,
	// node_map_version, creation time) that a follow-up purge can
	// verify the token is still valid. Tokens are in-memory only; a
	// process restart invalidates all outstanding tokens, which is
	// the safe default for a destructive operation.
	struct orphan_scan_token {
		string   token;
		uint64_t node_map_version;
		uint64_t orphan_count;
		uint64_t orphan_bytes;
		time_t   issued_at;
	};

protected:
	static const type _type = storage::type_rocksdb;

	rocksdb::DB* _db;
	// REPLICATION METADATA column family (design §3.7): one row per key that
	// a delivery has been applied to, holding the source epoch, the order
	// label and whether that label was a delete (a tombstone). Kept out of
	// the default column family so it never shows up in iteration, dumps,
	// counts or the key space, and so it can be dropped wholesale when this
	// copy is replaced. Written ONLY by the apply paths — a master's own
	// client writes do not need it, and a demoted master rebuilds anyway.
	rocksdb::ColumnFamilyHandle* _cf_default;
	rocksdb::ColumnFamilyHandle* _cf_meta;
	// Serialization between the two delivery paths (design §3.8). The WAL
	// applier takes this EXCLUSIVELY for decode->decide->write->GC; a
	// forwarded change takes it SHARED and additionally the key's slot lock.
	// Lock order everywhere: _repl_apply_lock -> _mutex_wholelock -> slot
	// locks in ascending index.
	pthread_rwlock_t _repl_apply_lock;
	AtomicCounter _repl_forward_applied;
	AtomicCounter _repl_forward_skipped;
	AtomicCounter _repl_wal_applied;
	AtomicCounter _repl_wal_skipped;
	AtomicCounter _repl_decode_refused;
	// T17 (2026-10-02): _repl_apply_lock hold and wait times, diagnostic
	// only. The follower applies a WAL batch holding the lock EXCLUSIVELY;
	// forwarded (live) writes take it SHARED and wait while a batch applies.
	AtomicCounter _repl_apply_lock_count;
	AtomicCounter _repl_apply_lock_hold_us;
	uint64_t _repl_apply_lock_hold_us_max;
	uint64_t _repl_apply_lock_wait_us_max;
	uint64_t _repl_forward_lock_wait_us_max;
	AtomicCounter _repl_tombstones_dropped;
	// Resume point for the chunked tombstone sweep.
	string _tombstone_sweep_cursor;
	rocksdb::Options _options;
	rocksdb::WriteOptions _write_options;
	rocksdb::ReadOptions _read_options;

	// Iteration support
	const rocksdb::Snapshot* _iter_snapshot;
	rocksdb::Iterator* _iter;
	bool _iter_first;

	// Configuration parameters
	uint64_t _block_cache_size_mb;
	uint64_t _write_buffer_size_mb;
	int _max_write_buffer_number;
	uint64_t _wal_ttl_seconds;
	uint64_t _wal_size_limit_mb;
	bool     _sync_writes;

	// Master identity token (this node's DB lineage identifier, persisted
	// in the reserved key `__flare_repl_master_id`). Populated by open().
	// Guarded by _mutex_master_id: set_master_id() runs on the
	// reconstruction thread (token adoption after a full dump) while op
	// worker threads read it concurrently, and std::string mutation is
	// not atomic.
	mutable pthread_rwlock_t _mutex_master_id;
	string _master_id;
	// Generations (design §3.1). Guarded by _mutex_generations; persisted
	// under the reserved keys above so they survive a restart unchanged.
	string _source_epoch;
	string _source_epoch_reason;
	string _incarnation;
	// Rebuild evidence: the (master_id, source epoch) of the source this
	// copy was last rebuilt from by a clean truncate + full dump whose source
	// identity matched at its start and its end. Empty = no evidence. It says
	// WHICH HISTORY the copy was rebuilt from; it is not a replication
	// position and not proof of being in sync. Persisted under
	// kReplRebuiltFromKey, guarded by _mutex_generations.
	string _rebuilt_from_master_id;
	string _rebuilt_from_epoch;
	string _copy_id;
	bool _copy_identity_consistent = false;
	// COPY RETENTION (design §3): this instance is a staging copy at
	// data_dir/staging-<attempt>, not the live one. It is never in the map,
	// never read, never a source; only the switch makes it live.
	bool _staging = false;
	// capacity (design §9): spec.rocksdb.rebuildReserveBytes; -1 = unset
	// (staged rebuilds stop). Why the last staged rebuild stopped ("" = not
	// blocked), for stats.
	int64_t _rebuild_reserve_bytes = -1;
	pthread_mutex_t _mutex_rebuild_status;
	string _rebuild_blocked;
	uint64_t _staged_switched = 0;
	uint64_t _staged_abandoned = 0;
	// design §10 (user decision 2026-10-07, item 3): a blocked staged rebuild
	// is PARKED — no transfer, no automatic retry — until the operator
	// resumes it (rebuild_resume) when a slot is free; in_flight = a staged
	// copy, catch-up or switch is running right now
	bool _rebuild_parked = false;
	bool _rebuild_in_flight = false;
	// design §9 / decision 2026-10-07 item 4: measured peaks, so the reserve
	// is set from measurements (receiver = staged rebuild, source = serve)
	struct peak_set {
		uint64_t data_dir_bytes = 0;		// largest size of the whole data dir seen
		int64_t memory_bytes = -1;			// largest cgroup memory use seen (-1 = not readable)
		int64_t min_available = -1;			// smallest rebuild_space_available seen (-1 = none)
		uint64_t start_data_dir_bytes = 0;	// data dir size when the window began
		uint64_t samples = 0;
		uint64_t last_sample_ms = 0;
	};
	peak_set _peaks_rebuild;
	peak_set _peaks_serve;
	// design §5: a snapshot (serve or push) is being served from this node
	bool _snapshot_serving = false;
	// design §6: the live copy is the empty copy left by a quarantine
	bool _quarantined = false;
	// review P1: a copy switch that failed and could not be PROVEN resolved
	// on disk (recovery refused, or the live directory is not the old copy).
	// Until the next start resolves it: no reopen / create, no further switch,
	// no destructive reset, not a healthy copy (no reads, not a source, not
	// promotable). Never cleared in this process.
	// a LEAF lock: nothing else is taken while it is held (lock order)
	pthread_mutex_t _mutex_switch_unresolved;
	bool _switch_unresolved = false;
	string _switch_unresolved_why;
	void _mark_switch_unresolved(const string& why);
	int _finalize_bulk_receipt(const string& pred, const string& succ, const string& epoch);
	bool _refuse_if_switch_unresolved(const char* who);
	// the source epoch the staged files carried when opened (a received
	// checkpoint), read BEFORE generations are initialised; "" = none
	string _staging_found_epoch;
	string _suspended_from_master_id;
	string _suspended_from_epoch;
	// Set when a generation could not be established or persisted. The
	// accessors then report "unavailable" and the replication paths refuse:
	// serving a changed history under an unchanged token is the failure this
	// guards against.
	bool _generations_broken;
	mutable pthread_rwlock_t _mutex_generations;

	// WAL replication observability counters. Read-only after increment;
	// exposed to `stats` via getter methods below. Incrementing happens
	// on the slave side for client-observed outcomes and on the master
	// side for server-side classifications.
	AtomicCounter _wal_sync_success;
	AtomicCounter _wal_sync_lsn_purged;
	AtomicCounter _wal_sync_lsn_ahead;
	AtomicCounter _wal_sync_master_id_mismatch;
	AtomicCounter _wal_sync_apply_failure;
	AtomicCounter _wal_sync_other_error;
	AtomicCounter _wal_sync_crc_mismatch;
	AtomicCounter _wal_fallback_to_dump;

	// Total entries physically reaped by the background expire crawler
	// (reap_expired) plus the lazy delete-on-get path. Monotonic.
	AtomicCounter _expire_reaped;
	// D1 (WSTR-0 audit): physically delete an entry found expired by get()
	// only on the partition MASTER (its delete reaches replicas through the
	// WAL). A replica filters the expired value but never deletes it by its
	// own clock — that would change its data outside the replication
	// history. Off until the cluster says this node is a master.
	volatile bool _lazy_expiry_delete;
	uint64_t _follow_generation;
	// Expired entries hidden from a read but NOT deleted (replica side).
	AtomicCounter _expire_filtered;

	// Completed snapshot bootstraps on this node (slave side: a physical
	// checkpoint reseed replaced the logical full dump). Monotonic.
	AtomicCounter _snapshot_bootstrap;

	// Corruption self-healing. `_corrupted` latches true the instant any
	// write path (Put/Delete/Write) returns a RocksDB Corruption status —
	// the poison state where reads still work but every write (and even
	// truncate) fails, so a normal reconstruction retry loops forever.
	// `_corruption_detected` counts detections (monotonic, for alerting);
	// `_hard_reset` counts in-process wipe+reopen recoveries. Exposed via
	// stats so the operator/alerts can act on the LATCH before an outage,
	// instead of discovering it on a client write.
	AtomicCounter _corruption_detected;
	AtomicCounter _hard_reset;
	AtomicCounter _rebuild_stale_discarded;
	volatile bool _corrupted;

	// Live (non-reserved) key count, maintained incrementally so `stats`
	// curr_items is O(1) instead of a full-keyspace iteration per call (the
	// exporter polls stats periodically — the old scan burned a whole
	// keyspace sweep per poll). Updated on every mutation path: set()/remove()
	// on the master (they already read prior existence), WriteBatch
	// application on the slave (apply_batch* walks the batch with an
	// existence-checking handler), truncate() resets to 0. Seeded at open()
	// from rocksdb.estimate-num-keys: exact 0 for a fresh DB; approximate
	// (± compaction-pending garbage + ≤2 reserved keys) after reopening an
	// existing directory — documented tradeoff, drift does not accumulate.
	AtomicCounter _curr_items;

	// Consecutive resync failure streak. Reset to 0 on success, so it
	// needs a non-monotonic reset operation — AtomicCounter only
	// supports add, so we use a plain counter under a dedicated mutex.
	// Access frequency is low (one update per resync attempt) so the
	// lock is uncontended in practice.
	mutable pthread_mutex_t _resync_failure_mutex;
	uint64_t                _resync_failure_count;

	// Threshold at which notify_resync_result(false) signals to the
	// caller that the slave should self-demote. 0 disables.
	int                     _resync_failure_threshold;

	// Phase D tuning: max bytes per replicated WAL batch (0 =
	// unlimited) and WAL-specific bandwidth throttle (0 = inherit
	// the cluster-wide reconstruction settings).
	uint64_t                _wal_max_batch_bytes;
	int                     _wal_sync_bwlimit;
	int                     _wal_sync_interval;
	// Snapshot-bootstrap stream cap in KB/s (0 = unlimited). Applied on the
	// SENDING side; defaults to ~1/4 of a 1 Gbps link so a reseed never
	// saturates the node NIC against serving traffic.
	int                     _snapshot_bwlimit;

	// Outstanding orphan scan token (at most one at a time). Guarded
	// by its own mutex; expected contention is zero because scans are
	// an operator-initiated activity.
	mutable pthread_mutex_t _orphan_scan_mutex;
	bool                    _orphan_scan_valid;
	orphan_scan_token       _orphan_scan;
	time_t                  _orphan_scan_ttl_seconds;

	// Named-checkpoint backups (logical-destruction protection). Backups
	// are RocksDB Checkpoints placed under _data_dir + "/backups/<name>".
	// _backup_keep bounds how many are retained (oldest pruned by name
	// order); _last_backup_epoch is the wall-clock time of the last
	// successful backup (0 = never) so monitoring can alert on staleness.
	int                     _backup_keep;
	time_t                  _last_backup_epoch;
	AtomicCounter           _backup_success;
	AtomicCounter           _backup_failure;

	virtual int _get_header(string key, entry& e);
	void _setup_rocksdb_options();

	// Load or generate the master identity token. Called from open() after
	// the DB handle is ready. Returns 0 on success, -1 on fatal I/O error.
	int _load_or_generate_master_id();
	// Load both generations, initialising them to 1 on a fresh DB. Called
	// from open() after the master id.
	int _load_or_init_generations();
	string _restore_pending_path() const;
	// 0: nothing to do or discarded cleanly. -1: a half-restored DB is on
	// disk and could NOT be removed — the caller must not open it.
	int _discard_incomplete_restore();
	void _release_snapshot_serve();
	// marker present and the live copy is the post-quarantine empty copy (or
	// the crash came before it was recorded)
	bool _quarantined_now();
	int _clear_quarantine_marker(const char* why);
	// exact count of live (non-reserved) keys -> curr_items; logs `why`
	void _seed_curr_items_by_scan(const char* why);
	int _persist_generation(const char* key, const string& value);
	int _clear_rebuilt_from_locked();
	// Open/close the DB with both column families, creating the metadata one
	// if the directory does not have it yet (an older DB, or a checkpoint
	// taken from a node that never applied a delivery).
	rocksdb::Status _open_db(const string& path);
	// Per-key replication metadata (design §3.7): "<epoch>|<label>|<0|1>".
	struct repl_meta {
		string   epoch;
		uint64_t label;
		bool     deleted;
		repl_meta(): label(0), deleted(false) {}
	};
	// 0: found. 1: absent. -1: read error.
	int _read_repl_meta(const string& key, repl_meta& out);
	void _stage_repl_meta(rocksdb::WriteBatch& batch, const string& key,
		const string& epoch, uint64_t label, bool deleted);
	// The rule itself, with no I/O: given what the key already carries, may a
	// change with (epoch,label) be applied?
	apply_outcome _decide_change(const string& epoch, uint64_t label,
		bool have_meta, const repl_meta& current, uint64_t applied_cursor);
	void _close_db();
	static const char* const kReplMetaCfName;
	// "<n>:<uuid>": n is monotonic within this DB and for humans; the uuid
	// makes the value unique across DBs and across repeated resets.
	static string _mint_generation(const string& previous);

public:
	storage_rocksdb(
		string data_dir,
		int mutex_slot_size,
		int header_cache_size,
		uint64_t block_cache_size_mb = 512,
		uint64_t write_buffer_size_mb = 64,
		int max_write_buffer_number = 3,
		uint64_t wal_ttl_seconds = 86400,
		uint64_t wal_size_limit_mb = 10240,
		bool sync_writes = false
	);
	virtual ~storage_rocksdb();

	virtual int open();
	virtual int close();
	virtual int set(entry& e, result& r, int b = 0);
	virtual int incr(entry& e, uint64_t value, result& r, bool increment, int b = 0);
	virtual int get(entry& e, result& r, int b = 0);
	virtual int remove(entry& e, result& r, int b = 0);
	virtual int truncate(int b = 0);
	virtual int iter_begin();
	virtual iteration iter_next(string& key);
	virtual int iter_end();

	// OFFLINE analysis: open a checkpoint dir READ-ONLY (no writes, no server,
	// no lineage side effects) and stream one CSV row per live key —
	// key,expire,ttl,size — to `out`, plus a one-line summary to stderr.
	// Streaming (constant memory) over the RocksDB cursor; blob-indexed values
	// are dereferenced transparently. Intended to run against an S3 BACKUP
	// checkpoint off the serving cluster, so the expensive full-header scan
	// never touches production. See docs/BACKUP_RESTORE.md.
	int analyze_checkpoint(const string& dir, FILE* out);
	virtual uint32_t count();
	virtual uint64_t size();
	virtual int reap_expired(time_t now, uint32_t max_scan, const string& after_key,
			string& last_key, bool& more, uint32_t& scanned, uint32_t& reaped,
			vector<entry>* reaped_entries = NULL);

	// Snapshot bootstrap (physical reseed = "snapshot + WAL catch-up" instead
	// of the logical full dump). Master side: create a RocksDB checkpoint in a
	// private staging dir and report the EXACT sequence number it captures —
	// everything after that seq is in the master's WAL, so a peer that swaps
	// this checkpoint in can finish with an incremental WAL sync from out_seq.
	// Caller must remove_snapshot_checkpoint() when done streaming.
	int create_snapshot_checkpoint(string& out_path, uint64_t& out_seq);
	int remove_snapshot_checkpoint(const string& path);
	// Pin SST + archived-WAL deletion while a snapshot (+ its WAL tail) is
	// being streamed, so the needed range cannot be purged mid-transfer no
	// matter how small wal-ttl/size caps are. MUST be paired with
	// enable_file_deletions() on every exit path; the cost while held is
	// disk growth bounded by the transfer duration.
	int disable_file_deletions();
	int enable_file_deletions();
	// Slave side: replace the live DB with the received checkpoint (staging
	// dir is renamed into place under the whole-storage write lock — readers
	// and writers are excluded for the swap) and seed the replication cursor
	// to the checkpoint's sequence. The master identity token travels INSIDE
	// the checkpoint (reserved key), so lineage is inherited automatically.
	int swap_in_snapshot(const string& staging_dir, uint64_t checkpoint_seq);
	// Prepare (wipe + mkdir) the receive-side staging dir and return its
	// path. Kept inside storage so callers never hand-construct DB paths.
	int prepare_snapshot_staging(string& out_dir);
	// Remove the receive staging dir (after a failed or refused bootstrap, so
	// the fallback full dump does not run next to an abandoned copy).
	int remove_snapshot_staging(const string& path);

	virtual type get_type() {
		return this->_type;
	};
	virtual bool is_capable(capability c);

	// RocksDB-specific methods for WAL replication
	uint64_t get_latest_sequence_number();
	// Read WAL updates from a sequence. max_batches/max_bytes bound what is
	// materialised: without them the whole backlog of a far-behind reader is
	// pulled into memory before a single byte is sent (design §4, condition
	// 7). 0 means unbounded, which is what the reconstruction path still
	// asks for. `more` says whether the iterator had further updates.
	int get_updates_since(uint64_t seq_number, vector<pair<uint64_t, rocksdb::WriteBatch>>& updates,
		uint64_t max_batches = 0, uint64_t max_bytes = 0, bool* more = NULL);
	// ---- COMMON APPLY RULE (design §3.3, §3.4, §3.5, §3.8) ----------------
	// Forwarded delivery of ONE change. Takes the apply lock in SHARED mode
	// plus this key's slot lock: forwarded changes stay concurrent with one
	// another and serialized per key, but never overlap the WAL applier's
	// window. The applied position is read INSIDE that section.
	virtual int apply_identified_change(const string& tag, entry& e, bool is_delete);

	apply_outcome apply_forwarded_change(const string& source_epoch,
		const string& incarnation, uint64_t label, entry& e, bool is_delete);

	// WAL delivery of one fetched batch, identified by the sequence RocksDB
	// gave it. Takes the apply lock EXCLUSIVELY, decodes the batch into
	// changes, decides each against the key's metadata and the earlier
	// changes of the same batch, and commits the survivors, their metadata,
	// the tombstone updates AND the new cursor in one WriteBatch — so a
	// crash between applying and recording the position cannot happen.
	// Returns 0 on success (counts filled), -1 when the batch was refused;
	// `refusal` then says why and nothing was written.
	int apply_wal_batch(const string& source_epoch, const string& incarnation,
		uint64_t base_seq, const rocksdb::WriteBatch& batch,
		uint64_t& applied, uint64_t& skipped, apply_outcome& refusal,
		uint64_t follow_generation = 0);
	// D7: every stop/start of the follower bumps the generation; a batch
	// carrying an older non-zero generation is refused under the apply lock,
	// so a stopped follower that is still finishing its slice writes nothing.
	virtual uint64_t bump_follow_generation() { return __sync_add_and_fetch(&this->_follow_generation, 1); }
	uint64_t get_follow_generation() { return __sync_add_and_fetch(&this->_follow_generation, 0); }

	// Drop tombstones the applied position has passed (design §3.5). Bounded
	// and resumable: called from inside the applier's window, never as a
	// long sweep. Returns how many were dropped.
	uint64_t collect_tombstones(uint64_t budget = 256);
private:
	// Same, with _repl_apply_lock already held exclusively.
	uint64_t _collect_tombstones_locked(uint64_t budget);
public:
	uint64_t get_repl_tombstones();
	// Test-only accessor: lets a unit test build a batch that targets the
	// replication-metadata family, which is what a source that has applied
	// deliveries carries in its own WAL.
	rocksdb::ColumnFamilyHandle* debug_meta_cf() { return this->_cf_meta; }

	uint64_t get_repl_forward_applied()   { return this->_repl_forward_applied.fetch(); }
	uint64_t get_repl_forward_skipped()   { return this->_repl_forward_skipped.fetch(); }
	uint64_t get_repl_wal_applied()       { return this->_repl_wal_applied.fetch(); }
	uint64_t get_repl_wal_skipped()       { return this->_repl_wal_skipped.fetch(); }
	uint64_t get_repl_decode_refused()    { return this->_repl_decode_refused.fetch(); }
	uint64_t get_repl_apply_lock_count()   { return this->_repl_apply_lock_count.fetch(); }
	uint64_t get_repl_apply_lock_hold_us() { return this->_repl_apply_lock_hold_us.fetch(); }
	uint64_t get_repl_apply_lock_hold_us_max()   { return __sync_fetch_and_add(&this->_repl_apply_lock_hold_us_max, 0); }
	uint64_t get_repl_apply_lock_wait_us_max()   { return __sync_fetch_and_add(&this->_repl_apply_lock_wait_us_max, 0); }
	uint64_t get_repl_forward_lock_wait_us_max() { return __sync_fetch_and_add(&this->_repl_forward_lock_wait_us_max, 0); }
	uint64_t get_repl_tombstones_dropped(){ return this->_repl_tombstones_dropped.fetch(); }

	int apply_batch(const rocksdb::WriteBatch& batch);
	int apply_batch_with_lsn(const rocksdb::WriteBatch& batch, uint64_t master_lsn);
	static bool validate_batch_rep(const rocksdb::WriteBatch& batch);
	uint64_t get_repl_last_lsn();
	// Durably overwrite the replication cursor (kReplLastLsnKey). Used to
	// seed the cursor after a full-dump reconstruction so the next WAL
	// sync can be incremental. Returns 0 on success, -1 on write failure.
	int set_repl_last_lsn(uint64_t lsn);

	// Master identity token access. `get_master_id()` returns this DB's
	// token (set at open(); empty only if open() was never called or
	// failed). `set_master_id()` overwrites and persists a new token,
	// used after a successful full dump or reconstruction from a different
	// master to adopt that master's lineage. Returns a copy (not a
	// reference) because the token can be rewritten concurrently by the
	// reconstruction thread; see _mutex_master_id.
	string get_master_id() const;
	string get_source_epoch();
	string get_source_epoch_reason();
	string get_incarnation();
	// Rebuild evidence (see _rebuilt_from_*). clear_rebuilt_from() durably
	// removes it (0 on success); set_rebuilt_from() durably records it (0 on
	// success; on failure the evidence stays absent, never half-written).
	string get_rebuilt_from_master_id();
	string get_rebuilt_from_epoch();
	int clear_rebuilt_from();
	int set_rebuilt_from(const string& master_id, const string& epoch);
	// R3-D: a rebuild attempt starts — the evidence stops being advertised
	// (no evidence is visible while the copy may change) but is kept,
	// durably and separately, as what the STORED copy is, so the protection
	// rule can still judge it after a restart. Cleared as soon as the stored
	// copy changes (truncate, swap, merge dump, a change of the local
	// history) and replaced when new evidence is recorded. 0 on success.
	string get_copy_id();
	// false: the reserved key and COPY_ID disagree (or the second write
	// failed) — not a normal healthy copy (design §2)
	bool copy_identity_consistent();
	// new uuid, generation 1 (a different copy); bump = same uuid, +1
	int new_copy_identity(const char* why);
	int bump_copy_generation(const char* why);
	// Replace the live copy with the verified, durable staging copy
	// data_dir/staging-<attempt> whose COPY_ID is `expected_new_id` (design
	// §4.1). The old copy is kept as data_dir/retained-<attempt>. 0 on success;
	// on failure the live copy is whatever the recovery table restores.
	int switch_to_staging(const string& attempt, const string& expected_new_id);
	// --- staging (design §3) ---
	// A new attempt id (also names staging-/retained- directories).
	static string new_attempt_id();
	// Open a separate instance on data_dir/staging-<attempt>: a NEW empty
	// directory (existing_files=false; refused if it exists) or the files a
	// snapshot transfer just wrote there (existing_files=true). It always gets
	// a new copy identity. NULL on failure (nothing left behind for a new dir).
	storage_rocksdb* open_staging(const string& attempt, bool existing_files);
	// Create the EMPTY directory data_dir/staging-<attempt> (refused if it
	// exists or is on another filesystem), for a transfer to write into.
	int make_staging_dir(const string& attempt, string& path);
	bool is_staging() const { return this->_staging; }
	void set_rebuild_reserve_bytes(int64_t b) { this->_rebuild_reserve_bytes = b; }
	int64_t get_rebuild_reserve_bytes() const { return this->_rebuild_reserve_bytes; }
	void set_rebuild_blocked(const string& why);
	string get_rebuild_blocked();
	void note_staged_result(bool switched);
	bool is_snapshot_serving();
	void set_rebuild_parked(bool b);
	bool is_rebuild_parked();
	// true if it was parked (the next attempt re-checks everything)
	bool resume_rebuild();
	void set_rebuild_in_flight(bool b);
	bool is_rebuild_in_flight();
	// peaks: start a measurement window, sample (at most once a second unless
	// forced), read. serve = the source side (snapshot / dump being served).
	void peaks_begin(bool serve);
	void peaks_sample(bool serve, bool force = false);
	void peaks_get(bool serve, uint64_t& data_dir_max, int64_t& memory_max, int64_t& min_available,
		uint64_t& data_dir_start, uint64_t& samples);
	bool is_quarantined() const { return this->_quarantined; }
	// one synchronized snapshot of the flag and its reason
	bool switch_unresolved_snapshot(string& why);
	bool is_switch_unresolved() { string w; return this->switch_unresolved_snapshot(w); }
	// receipts of completed bulks, "<pred> <succ> <epoch>" per line
	string get_bulk_chain();
	int recover_bulk_pending();
	bool has_bulk_pending();
	bool promotion_forbidden(std::string& why);
	int check_partition_binding(const std::string& want, bool as_master, std::string& why);
	// "" = no binding recorded (or unreadable: see the -1 of the check)
	string get_partition_binding();
	bool is_restored_unverified();
	// the content is being replaced by a rebuild: the old binding and the
	// restored flag no longer describe it (0 on success)
	int drop_partition_binding(const char* why);
	// "partition=<p>" ... fields of a binding; false when malformed
	static bool parse_partition_binding(const string& b, std::map<string, string>& out);
	// a checkpoint's binding, read-only (flared --checkpoint-binding)
	static int checkpoint_binding(const string& dir, string& binding, bool& restored_unverified);
	// decision 2026-10-08: data_dir/copy.partial — the live copy is being (or
	// was left) changed part-way by a merging dump. Written durably BEFORE the
	// first change, removed only on confirmed success; survives a crash.
	int mark_copy_partial(const char* why);
	int clear_copy_partial(const char* why);
	bool is_copy_partial();
	// design §7: an explicit, one-shot approval to discard ONE named copy.
	// operation: discard-retained | discard-quarantine | discard-before-copy.
	// request_id is recorded durably BEFORE anything is deleted and with its
	// result after: the same request id never runs twice (also across a crash
	// between the two records). discard-before-copy needs `may_discard_live`
	// (the caller checked this node is neither a master nor an Active slave). `result` is one of
	// applied, already:<recorded>, refused:<reason>. 0 = answered.
	int discard_copy(const string& request_id, const string& operation, const string& copy_id,
		bool may_discard_live, string& result);
	static const char* const kApprovalsFile;
	uint64_t get_staged_switched();
	uint64_t get_staged_abandoned();
	// The source epoch the staged files carried (received checkpoint), "" if none.
	string get_staging_found_epoch() const { return this->_staging_found_epoch; }
	// Staging only: this copy follows (master_id, epoch) from `cursor` on
	// (epoch "" = a source without epochs: the copy keeps its own) —
	// drops inherited replication metadata and rebuild evidence, mints a new
	// incarnation, one synced batch. 0 on success.
	int adopt_history(const string& master_id, const string& epoch, uint64_t cursor);
	// Staging only: flush, sync the WAL, close, fsync the copy's directory
	// and data_dir. After this the copy is durable and closed. 0 on success.
	int seal();
	// Remove data_dir/staging-<attempt> (an abandoned attempt). 0 on success.
	int remove_staging(const string& attempt);
	// After a switch: record in retained-<attempt> what replaced it (the new
	// copy id and the source it was verified against). Durable. 0 on success.
	int record_retained(const string& attempt, const string& master_id, const string& epoch);
	// Names of retained-* directories present (attempt ids).
	vector<string> list_retained();
	// bytes under data_dir entries whose name starts with `prefix`
	// (retained-, quarantine-, staging-): what the copies kept here take
	uint64_t bytes_with_prefix(const string& prefix);
	// Design §8: delete every retained copy whose four conditions hold
	// (record present; live copy id = the one that replaced it and the
	// identity is consistent; the read source bound eligible to the recorded
	// lineage and history; this replica Active in its own map). Returns the
	// number removed; `report` says why each one was kept.
	int reap_retained(const string& bound_master_id, const string& bound_epoch, bool bound_eligible, bool own_active, string& report);
	int suspend_rebuilt_from();
	int clear_suspended_rebuilt_from();
	string get_suspended_rebuilt_from_master_id();
	string get_suspended_rebuilt_from_epoch();
	// The rule for recording it, stated once: only a clean rebuild (the
	// local copy was truncated first) whose dump succeeded, from a source
	// that advertised a non-empty identity that did not change between the
	// start and the end of the dump.
	static bool rebuild_evidence_valid(bool truncated, bool dump_ok,
		const string& start_master_id, const string& start_epoch,
		const string& end_master_id, const string& end_epoch);
	// Mint, persist and publish a fresh identity. 0 on success; on failure
	// the generations become UNAVAILABLE (fail closed) and -1 is returned.
	int advance_source_epoch(const char* reason = "unspecified");
	int advance_incarnation();
	bool generations_broken() const;
	int set_master_id(const string& id);
	// Mint and persist a brand-new master_id (fresh UUID). Called at
	// promotion to master when this node carries a replication cursor from a
	// former master's sequence space (repl_last_lsn > latest_sequence_number),
	// so same-lineage slaves see a clean lineage break and take a correct full
	// dump instead of stranding on lsn_ahead / the #14 truncate-skip. See the
	// call site in cluster::_shift_node_role.
	int regenerate_master_id();

	// WAL sync observability. All counters are monotonically increasing
	// (except get_resync_failure_count() which is the current streak,
	// reset to zero on success). Readers should treat each call as a
	// point-in-time sample.
	uint64_t get_wal_sync_success()           { return this->_wal_sync_success.fetch(); }
	uint64_t get_wal_sync_lsn_purged()        { return this->_wal_sync_lsn_purged.fetch(); }
	uint64_t get_wal_sync_lsn_ahead()         { return this->_wal_sync_lsn_ahead.fetch(); }
	uint64_t get_wal_sync_master_id_mismatch(){ return this->_wal_sync_master_id_mismatch.fetch(); }
	uint64_t get_wal_sync_apply_failure()     { return this->_wal_sync_apply_failure.fetch(); }
	uint64_t get_wal_sync_other_error()       { return this->_wal_sync_other_error.fetch(); }
	uint64_t get_wal_sync_crc_mismatch()      { return this->_wal_sync_crc_mismatch.fetch(); }
	uint64_t get_wal_fallback_to_dump()       { return this->_wal_fallback_to_dump.fetch(); }
	uint64_t get_expire_reaped()              { return this->_expire_reaped.fetch(); }
	virtual void set_lazy_expiry_delete(bool on) { this->_lazy_expiry_delete = on; }
	bool get_lazy_expiry_delete() const       { return this->_lazy_expiry_delete; }
	uint64_t get_expire_filtered()            { return this->_expire_filtered.fetch(); }
	uint64_t get_snapshot_bootstrap()         { return this->_snapshot_bootstrap.fetch(); }
	void incr_snapshot_bootstrap()            { this->_snapshot_bootstrap.incr(); }
	uint64_t get_corruption_detected()        { return this->_corruption_detected.fetch(); }
	uint64_t get_hard_reset()                 { return this->_hard_reset.fetch(); }
	uint64_t get_rebuild_stale_discarded()    { return this->_rebuild_stale_discarded.fetch(); }
	void incr_rebuild_stale_discarded()       { this->_rebuild_stale_discarded.incr(); }
	// SPACE-AWARE REBUILD. A physical reseed stages the incoming copy next to
	// the local one, so a rebuild in place needs room for two copies; on tmpfs
	// that room is RAM counted against the container's memory limit.
	// Bytes of the local DB directory (the estimate of the incoming copy).
	uint64_t local_copy_bytes();
	// Bytes free for a staging copy: free space under the data dir and, when
	// the data dir is tmpfs, the smaller of that and the cgroup memory
	// headroom (limit - current usage, which includes the tmpfs pages and
	// flared). No fixed margin: the configured reserve covers flared's growth.
	// -1 = unknown (no decision possible).
	int64_t rebuild_space_available();
	// True once a Corruption status has been seen on a write path; latched
	// until a successful hard_reset()/reopen clears it.
	bool is_corrupted()                       { return this->_corrupted; }
	// Verify every SST/blob checksum (RocksDB DB::VerifyChecksum). Returns 0
	// if clean, -1 on corruption (latches _corrupted + bumps the counter).
	// Expensive (reads all files) — driven by the opt-in storage-check thread.
	int verify_integrity();
	// In-process Case-A recovery: close the DB, remove the data directory,
	// reopen empty, reset counters, clear the corruption latch. Returns 0 on
	// success. The CALLER must ensure this node is not the last good copy
	// (only a SLAVE / a reconstructing node), because it discards all local
	// data unconditionally — reconstruction reseeds it afterwards.
	int hard_reset();
	// R3-D: a CORRUPT copy is not proof that nothing valuable is in it. Move
	// it aside (data dir / quarantine-<time>-<pid>) instead of deleting it,
	// then reopen empty. If it cannot be moved aside, NOTHING is deleted and
	// -1 is returned (the caller stops). `moved_to` names where it went.
	int quarantine_reset(string& moved_to);

protected:
	// Latch corruption from a write-path status. Returns status.ok() so call
	// sites can `if (!_note_write_status(st)) { ... }` inline.
	bool _note_write_status(const rocksdb::Status& status, const char* where);

	// ENOSPC hardening (see the .cc docstrings): prune named backups to the
	// newest `keep`, and the last-ditch empty-reopen used when a teardown/
	// reopen (swap_in_snapshot / hard_reset) fails.
	void _prune_named_backups(int keep);
	int _emergency_reopen_empty(const char* who);

public:
	uint64_t get_resync_failure_count();

	// Observability mutators. Callers on the sync code paths invoke
	// these; tests may also call them directly to verify behavior.
	void incr_wal_sync_success()           { this->_wal_sync_success.incr(); }
	void incr_wal_sync_lsn_purged()        { this->_wal_sync_lsn_purged.incr(); }
	void incr_wal_sync_lsn_ahead()         { this->_wal_sync_lsn_ahead.incr(); }
	void incr_wal_sync_master_id_mismatch(){ this->_wal_sync_master_id_mismatch.incr(); }
	void incr_wal_sync_apply_failure()     { this->_wal_sync_apply_failure.incr(); }
	void incr_wal_sync_other_error()       { this->_wal_sync_other_error.incr(); }
	void incr_wal_sync_crc_mismatch()      { this->_wal_sync_crc_mismatch.incr(); }
	void incr_wal_fallback_to_dump()       { this->_wal_fallback_to_dump.incr(); }

	// Resync failure tracking. `notify_resync_result(true)` records a
	// successful resynchronization (WAL or full dump) and resets the
	// streak counter to 0. `notify_resync_result(false)` increments it
	// and returns the new value.
	uint64_t notify_resync_result(bool success);

	// Policy: configured threshold (0 = disabled) and helper that
	// answers "should the caller self-demote now, given the current
	// streak?". Separating the check from the update lets tests and
	// operators inspect state without side effects.
	void set_resync_failure_threshold(int threshold) {
		this->_resync_failure_threshold = threshold;
	}
	int get_resync_failure_threshold() const {
		return this->_resync_failure_threshold;
	}
	bool should_self_demote();

	// Phase D: WAL streaming limits. Set at startup from ini_option
	// and read by op_repl_sync_wal configured via handler_dump_replication.
	void set_wal_max_batch_bytes(uint64_t n) { this->_wal_max_batch_bytes = n; }
	void set_wal_sync_bwlimit(int kbps)      { this->_wal_sync_bwlimit    = kbps; }
	void set_snapshot_bwlimit(int v)          { this->_snapshot_bwlimit = v; }
	void set_wal_sync_interval(int usec)     { this->_wal_sync_interval   = usec; }
	uint64_t get_wal_max_batch_bytes() const { return this->_wal_max_batch_bytes; }
	int get_wal_sync_bwlimit() const         { return this->_wal_sync_bwlimit; }
	int get_snapshot_bwlimit()                { return this->_snapshot_bwlimit; }
	int get_wal_sync_interval() const        { return this->_wal_sync_interval; }

	// Record a scan result and return the newly issued token. Any
	// prior outstanding token is discarded: only the most recent scan
	// can be acted upon, which keeps the invariant simple.
	string remember_orphan_scan(uint64_t node_map_version,
	                            uint64_t orphan_count,
	                            uint64_t orphan_bytes);

	// Look up an outstanding token and copy its recorded state into
	// `out`. Returns true if `token` matches the active outstanding
	// scan and has not expired (configurable window, default 300s).
	// On false, `out` is unchanged.
	bool lookup_orphan_scan(const string& token, orphan_scan_token& out);

	// Discard any outstanding token. Called implicitly after a
	// successful purge so the same token cannot be replayed.
	void clear_orphan_scan();

	// Validity window for an outstanding orphan scan token, in seconds
	// (default 300). Exposed so operators can tune how long a scan result
	// stays actionable and so tests can drive the TTL-expiry path without
	// a multi-minute sleep.
	void set_orphan_scan_ttl_seconds(time_t seconds) {
		this->_orphan_scan_ttl_seconds = seconds;
	}
	time_t get_orphan_scan_ttl_seconds() const {
		return this->_orphan_scan_ttl_seconds;
	}

	// Create a RocksDB Checkpoint (a consistent, hard-linked snapshot of
	// the live DB) under _data_dir + "/backups/<name>". `name` must be a
	// simple, non-empty identifier ([A-Za-z0-9._-], no leading '.', no
	// '/') — this is a path-traversal guard, since the name becomes a
	// directory component. On success returns 0 and sets out_path to the
	// checkpoint directory; on any failure returns -1. After a successful
	// checkpoint, prunes sibling backups down to the newest _backup_keep
	// by lexical name order (callers are expected to use sortable
	// timestamp-prefixed names so lexical order == chronological order).
	int create_named_backup(const string& name, string& out_path);

	// Retention: how many backups to keep under backups/ (default 7).
	void set_backup_keep(int n) { this->_backup_keep = n; }
	int  get_backup_keep() const { return this->_backup_keep; }

	// Wall-clock epoch of the last successful backup (0 = never).
	time_t get_last_backup_epoch() const { return this->_last_backup_epoch; }

	// Backup observability counters (monotonic).
	uint64_t get_backup_success() { return this->_backup_success.fetch(); }
	uint64_t get_backup_failure() { return this->_backup_failure.fetch(); }
	void incr_backup_success()    { this->_backup_success.incr(); }
	void incr_backup_failure()    { this->_backup_failure.incr(); }
};

}   // namespace flare
}   // namespace gree

#endif  // STORAGE_ROCKSDB_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
