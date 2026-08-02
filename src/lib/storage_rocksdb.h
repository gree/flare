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
	static const int ERR_LSN_PURGED       = -1;
	static const int ERR_LSN_INVALID      = -2;
	static const int ERR_LSN_AHEAD        = -3;  // slave's LSN > master's latest
	static const int ERR_MASTER_ID_MISMATCH = -4;

	// Reserved metadata keys (hidden from get/set/remove/iter/truncate).
	// Defined in the .cc so they link once across TUs.
	static const char* const kReplLastLsnKey;
	static const char* const kReplMasterIdKey;

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
	AtomicCounter _wal_fallback_to_dump;

	// Total entries physically reaped by the background expire crawler
	// (reap_expired) plus the lazy delete-on-get path. Monotonic.
	AtomicCounter _expire_reaped;

	// Completed snapshot bootstraps on this node (slave side: a physical
	// checkpoint reseed replaced the logical full dump). Monotonic.
	AtomicCounter _snapshot_bootstrap;

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
	virtual uint32_t count();
	virtual uint64_t size();
	virtual int reap_expired(time_t now, uint32_t max_scan, const string& after_key,
			string& last_key, bool& more, uint32_t& scanned, uint32_t& reaped);

	// Snapshot bootstrap (physical reseed = "snapshot + WAL catch-up" instead
	// of the logical full dump). Master side: create a RocksDB checkpoint in a
	// private staging dir and report the EXACT sequence number it captures —
	// everything after that seq is in the master's WAL, so a peer that swaps
	// this checkpoint in can finish with an incremental WAL sync from out_seq.
	// Caller must remove_snapshot_checkpoint() when done streaming.
	int create_snapshot_checkpoint(string& out_path, uint64_t& out_seq);
	int remove_snapshot_checkpoint(const string& path);
	// Slave side: replace the live DB with the received checkpoint (staging
	// dir is renamed into place under the whole-storage write lock — readers
	// and writers are excluded for the swap) and seed the replication cursor
	// to the checkpoint's sequence. The master identity token travels INSIDE
	// the checkpoint (reserved key), so lineage is inherited automatically.
	int swap_in_snapshot(const string& staging_dir, uint64_t checkpoint_seq);
	// Prepare (wipe + mkdir) the receive-side staging dir and return its
	// path. Kept inside storage so callers never hand-construct DB paths.
	int prepare_snapshot_staging(string& out_dir);

	virtual type get_type() {
		return this->_type;
	};
	virtual bool is_capable(capability c);

	// RocksDB-specific methods for WAL replication
	uint64_t get_latest_sequence_number();
	int get_updates_since(uint64_t seq_number, vector<pair<uint64_t, rocksdb::WriteBatch>>& updates);
	int apply_batch(const rocksdb::WriteBatch& batch);
	int apply_batch_with_lsn(const rocksdb::WriteBatch& batch, uint64_t master_lsn);
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
	uint64_t get_wal_fallback_to_dump()       { return this->_wal_fallback_to_dump.fetch(); }
	uint64_t get_expire_reaped()              { return this->_expire_reaped.fetch(); }
	uint64_t get_snapshot_bootstrap()         { return this->_snapshot_bootstrap.fetch(); }
	void incr_snapshot_bootstrap()            { this->_snapshot_bootstrap.incr(); }
	uint64_t get_resync_failure_count();

	// Observability mutators. Callers on the sync code paths invoke
	// these; tests may also call them directly to verify behavior.
	void incr_wal_sync_success()           { this->_wal_sync_success.incr(); }
	void incr_wal_sync_lsn_purged()        { this->_wal_sync_lsn_purged.incr(); }
	void incr_wal_sync_lsn_ahead()         { this->_wal_sync_lsn_ahead.incr(); }
	void incr_wal_sync_master_id_mismatch(){ this->_wal_sync_master_id_mismatch.incr(); }
	void incr_wal_sync_apply_failure()     { this->_wal_sync_apply_failure.incr(); }
	void incr_wal_sync_other_error()       { this->_wal_sync_other_error.incr(); }
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
