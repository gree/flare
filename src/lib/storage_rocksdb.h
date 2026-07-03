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

	// Reserved metadata keys (hidden from get/set/remove/iter/truncate).
	// Defined in the .cc so they link once across TUs.
	static const char* const kReplLastLsnKey;
	static const char* const kReplMasterIdKey;
	static const char* const kReplSourceIdKey;
	static const char* const kRecordCountKey;

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

	// Iteration support. `_mutex_iter_lock` serializes the busy-check
	// and cursor setup/teardown in iter_begin()/iter_end() (matching
	// storage_tcb); `_mutex_wholelock` is additionally held (read) for
	// the duration of an iteration.
	mutable pthread_mutex_t _mutex_iter_lock;
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

	// Exact number of user records (reserved keys excluded), maintained
	// on every create/delete so count() is O(1) — RocksDB has no cheap
	// exact count (rocksdb.estimate-num-keys is approximate). Persisted
	// to kRecordCountKey on clean close and re-seeded by a one-time scan
	// after a crash (the marker is durably deleted right after loading).
	AtomicCounter _record_count;

	// Master identity token (this node's DB lineage identifier, persisted
	// in the reserved key `__flare_repl_master_id`). Populated by open()
	// and overwritten at runtime by set_master_id() (reconstruction /
	// seed), so every access goes through `_mutex_master_id` — readers
	// run on op worker threads concurrently with the writer.
	mutable pthread_mutex_t _mutex_master_id;
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

	// Outstanding orphan scan token (at most one at a time). Guarded
	// by its own mutex; expected contention is zero because scans are
	// an operator-initiated activity.
	mutable pthread_mutex_t _orphan_scan_mutex;
	bool                    _orphan_scan_valid;
	orphan_scan_token       _orphan_scan;
	time_t                  _orphan_scan_ttl_seconds;

	virtual int _get_header(string key, entry& e);
	void _setup_rocksdb_options();

	// Load or generate the master identity token. Called from open() after
	// the DB handle is ready. Returns 0 on success, -1 on fatal I/O error.
	int _load_or_generate_master_id();

	// Initialize _record_count at open(): load the count persisted by the
	// last clean close, or fall back to a one-time full scan.
	int _load_or_count_records();

	// Common implementation of apply_batch()/apply_batch_with_lsn():
	// filters reserved keys out of the incoming batch (a peer's metadata
	// markers must never overwrite ours), computes the record-count
	// delta, optionally appends our own LSN marker, and commits
	// atomically under the whole lock.
	int _apply_batch_filtered(const rocksdb::WriteBatch& batch, const string* lsn_value);

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

	virtual type get_type() {
		return this->_type;
	};
	virtual bool is_capable(capability c);

	// RocksDB-specific methods for WAL replication.
	// get_updates_since() returns every WAL batch after `seq_number`
	// (the first returned batch may overlap it; re-application is
	// idempotent). It fails with ERR_LSN_PURGED when the WAL no longer
	// covers the requested position — callers must then fall back to a
	// full resync. `max_total_bytes` (0 = unlimited) bounds the bytes
	// accumulated per call; when the budget is hit, `has_more` (if
	// non-NULL) is set and the caller should fetch again from the last
	// applied sequence.
	uint64_t get_latest_sequence_number();
	int get_updates_since(uint64_t seq_number, vector<pair<uint64_t, rocksdb::WriteBatch>>& updates,
		uint64_t max_total_bytes = 0, bool* has_more = NULL);
	int apply_batch(const rocksdb::WriteBatch& batch);
	int apply_batch_with_lsn(const rocksdb::WriteBatch& batch, uint64_t master_lsn);
	uint64_t get_repl_last_lsn();
	int set_repl_last_lsn(uint64_t lsn);

	// Upstream replication source tracking (destination side). The
	// source id names the physical DB (= WAL sequence domain) whose
	// positions repl_last_lsn refers to; it is distinct from this
	// node's own master_id, which never changes for the lifetime of
	// the local DB. Recorded atomically together with the position by
	// `repl_sync_wal seed`.
	string get_repl_source_id();
	int set_repl_source(const string& source_id, uint64_t lsn);

	// Testing hook: flush the memtable and delete archived WAL files so
	// that a subsequent get_updates_since() below the flushed sequence
	// hits the purged-WAL path. Returns true only when it has confirmed
	// (via a direct GetUpdatesSince probe) that early sequences are no
	// longer retrievable — so a test can hard-assert ERR_LSN_PURGED —
	// and false if the environment retained the WAL. This exercises the
	// ERR_LSN_PURGED continuity check without waiting for the time-/
	// size-based WAL retention to trigger.
	bool flush_and_purge_wal_for_test();

	// Master identity token access. `get_master_id()` returns this DB's
	// token (set at open(); empty only if open() was never called or
	// failed). `set_master_id()` overwrites and persists a new token,
	// used after a successful full dump or reconstruction from a different
	// master to adopt that master's lineage. Returns by value under the
	// token mutex — the writer runs on a different thread than readers.
	string get_master_id() const {
		pthread_mutex_lock(&this->_mutex_master_id);
		string id = this->_master_id;
		pthread_mutex_unlock(&this->_mutex_master_id);
		return id;
	}
	int set_master_id(const string& id);

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
	void set_wal_sync_interval(int usec)     { this->_wal_sync_interval   = usec; }
	uint64_t get_wal_max_batch_bytes() const { return this->_wal_max_batch_bytes; }
	int get_wal_sync_bwlimit() const         { return this->_wal_sync_bwlimit; }
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
};

}   // namespace flare
}   // namespace gree

#endif  // STORAGE_ROCKSDB_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
