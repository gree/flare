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
 *  storage_rocksdb.cc
 *
 *  implementation of gree::flare::storage_rocksdb
 *
 *  $Id$
 */
#include "app.h"
#include <sys/statvfs.h>
#include <sys/vfs.h>
#include "storage_rocksdb.h"
#include "copy_switch_fs.h"
#include <time.h>

#include <rocksdb/utilities/checkpoint.h>

#include <uuid/uuid.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/types.h>
#include <dirent.h>
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <algorithm>
#include <map>
#include <vector>

namespace gree {
namespace flare {

// T17 lock timing helpers (diagnostic only).
static inline uint64_t repl_now_us() {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}
static inline void repl_atomic_max(uint64_t* p, uint64_t v) {
	uint64_t cur = __sync_fetch_and_add(p, 0);
	while (v > cur && !__sync_bool_compare_and_swap(p, cur, v)) {
		cur = __sync_fetch_and_add(p, 0);
	}
}

// {{{ reserved keys
// Keys used by the WAL replication subsystem for per-slave metadata.
// They are hidden from get/set/remove/iter/truncate so that user-visible
// operations cannot accidentally clobber or observe them.
const char* const storage_rocksdb::kReplLastLsnKey  = "__flare_repl_last_lsn";
const char* const storage_rocksdb::kReplMasterIdKey = "__flare_repl_master_id";
// Generations (design §3.1) and the restore completion marker (§3.9(D)).
const char* const storage_rocksdb::kReplSourceEpochKey = "__flare_repl_source_epoch";
const char* const storage_rocksdb::kReplSourceEpochReasonKey = "__flare_repl_source_epoch_reason";
const char* const storage_rocksdb::kReplIncarnationKey = "__flare_repl_incarnation";
const char* const storage_rocksdb::kReplRestoreDoneKey = "__flare_repl_restore_done";
// Rebuild evidence: "<master_id> <source epoch> <own epoch>" — the clean
// full-dump source, bound to THIS node's own source epoch at recording time.
const char* const storage_rocksdb::kReplRebuiltFromKey = "__flare_repl_rebuilt_from";
// Same format, the evidence of the stored copy while a rebuild is in progress.
const char* const storage_rocksdb::kReplRebuiltFromSuspendedKey = "__flare_repl_rebuilt_from_suspended";
const char* const storage_rocksdb::kCopyIdKey = "__flare_copy_id";
const char* const storage_rocksdb::kQuarantineMarkerFile = "quarantine.marker";
const char* const storage_rocksdb::kApprovalsFile = "approvals.log";
// Name of the replication-metadata column family (design §3.7).
const char* const storage_rocksdb::kReplMetaCfName = "flare_repl_meta";

bool storage_rocksdb::is_reserved_key(const string& key) {
	return key == kReplLastLsnKey || key == kReplMasterIdKey
		|| key == kReplSourceEpochKey || key == kReplSourceEpochReasonKey || key == kReplIncarnationKey
		|| key == kReplRestoreDoneKey || key == kReplRebuiltFromKey || key == kReplRebuiltFromSuspendedKey || key == kCopyIdKey;
}
// }}}

// {{{ ctor/dtor
/**
 *  ctor for storage_rocksdb
 */
storage_rocksdb::storage_rocksdb(
	string data_dir,
	int mutex_slot_size,
	int header_cache_size,
	uint64_t block_cache_size_mb,
	uint64_t write_buffer_size_mb,
	int max_write_buffer_number,
	uint64_t wal_ttl_seconds,
	uint64_t wal_size_limit_mb,
	bool sync_writes
):
	storage(data_dir, mutex_slot_size, header_cache_size),
	_db(NULL),
	_cf_default(NULL),
	_cf_meta(NULL),
	_iter_snapshot(NULL),
	_iter(NULL),
	_iter_first(false),
	_block_cache_size_mb(block_cache_size_mb),
	_write_buffer_size_mb(write_buffer_size_mb),
	_max_write_buffer_number(max_write_buffer_number),
	_wal_ttl_seconds(wal_ttl_seconds),
	_wal_size_limit_mb(wal_size_limit_mb),
	_sync_writes(sync_writes),
	_master_id(""),
	_source_epoch(""),
	_incarnation(""),
	_generations_broken(false),
	_repl_forward_applied(0),
	_repl_forward_skipped(0),
	_repl_wal_applied(0),
	_repl_wal_skipped(0),
	_repl_decode_refused(0),
	_repl_apply_lock_count(0),
	_repl_apply_lock_hold_us(0),
	_repl_apply_lock_hold_us_max(0),
	_repl_apply_lock_wait_us_max(0),
	_repl_forward_lock_wait_us_max(0),
	_repl_tombstones_dropped(0),
	_wal_sync_success(0),
	_wal_sync_lsn_purged(0),
	_wal_sync_lsn_ahead(0),
	_wal_sync_master_id_mismatch(0),
	_wal_sync_apply_failure(0),
	_wal_sync_other_error(0),
	_wal_sync_crc_mismatch(0),
	_wal_fallback_to_dump(0),
	_expire_reaped(0),
	_lazy_expiry_delete(false),
	_follow_generation(0),
	_expire_filtered(0),
	_snapshot_bootstrap(0),
	_corruption_detected(0),
	_hard_reset(0),
	_rebuild_stale_discarded(0),
	_corrupted(false),
	_curr_items(0),
	_resync_failure_count(0),
	_resync_failure_threshold(0),
	_wal_max_batch_bytes(0),
	_wal_sync_bwlimit(0),
	_wal_sync_interval(0),
	_snapshot_bwlimit(32768),
	_orphan_scan_valid(false),
	_orphan_scan_ttl_seconds(300),
	_backup_keep(7),
	_last_backup_epoch(0),
	_backup_success(0),
	_backup_failure(0) {
	pthread_mutex_init(&this->_resync_failure_mutex, NULL);
	pthread_rwlock_init(&this->_mutex_generations, NULL);
	pthread_rwlock_init(&this->_repl_apply_lock, NULL);
	pthread_mutex_init(&this->_orphan_scan_mutex, NULL);
	pthread_rwlock_init(&this->_mutex_master_id, NULL);
	pthread_mutex_init(&this->_mutex_rebuild_status, NULL);
	this->_data_path = this->_data_dir + "/flare.rocksdb";
	this->_setup_rocksdb_options();
}

/**
 *  dtor for storage_rocksdb
 */
storage_rocksdb::~storage_rocksdb() {
	if (this->_open) {
		this->close();
	}
	this->_close_db();
	pthread_rwlock_destroy(&this->_repl_apply_lock);
	pthread_rwlock_destroy(&this->_mutex_generations);
	pthread_mutex_destroy(&this->_resync_failure_mutex);
	pthread_mutex_destroy(&this->_orphan_scan_mutex);
	pthread_rwlock_destroy(&this->_mutex_master_id);
	pthread_mutex_destroy(&this->_mutex_rebuild_status);
}
// }}}

// {{{ private methods
/**
 *  setup RocksDB options
 */
void storage_rocksdb::_setup_rocksdb_options() {
	// Create LRU block cache (replaces TCMAP header cache)
	rocksdb::BlockBasedTableOptions table_options;
	table_options.block_cache = rocksdb::NewLRUCache(this->_block_cache_size_mb * 1024 * 1024);
	this->_options.table_factory.reset(rocksdb::NewBlockBasedTableFactory(table_options));

	// MemTable configuration
	this->_options.write_buffer_size = this->_write_buffer_size_mb * 1024 * 1024;
	this->_options.max_write_buffer_number = this->_max_write_buffer_number;

	// Enable blob files for large values (memcached often has large values)
	this->_options.enable_blob_files = true;
	this->_options.min_blob_size = 4096;  // Values >= 4KB go to blob files

	// WAL retention configuration
	this->_options.WAL_ttl_seconds = this->_wal_ttl_seconds;
	this->_options.WAL_size_limit_MB = this->_wal_size_limit_mb;
	this->_options.keep_log_file_num = 1000;

	// General settings
	this->_options.create_if_missing = true;
	this->_options.max_open_files = -1;  // Keep all files open

	// Write options. `sync` is configurable via ini_option's
	// `rocksdb_sync_writes` — default false keeps the established
	// performance characteristic; operators on ephemeral single-AZ
	// storage can flip it on for stricter durability.
	this->_write_options.sync = this->_sync_writes;
	this->_write_options.disableWAL = false;  // Keep WAL enabled for replication

	// Read options
	this->_read_options.verify_checksums = true;
}

/**
 *  get header from storage
 */
int storage_rocksdb::_get_header(string key, entry& e) {
	rocksdb::Status status;
	string value;

	if (this->_db == NULL) {
		// Handle closed by a failed reopen (ENOSPC path) — report cleanly.
		return -1;
	}

	status = this->_db->Get(this->_read_options, key, &value);

	if (!status.ok()) {
		if (status.IsNotFound()) {
			// Check header cache for deleted entries (matching storage_tcb behavior)
			this->_get_header_cache(key, e);
			return -1;
		}
		log_err("RocksDB::Get() failed: %s", status.ToString().c_str());
		return -1;
	}

	if (value.size() < static_cast<size_t>(entry::header_size)) {
		log_err("invalid header size (key=%s, size=%zu)", key.c_str(), value.size());
		return -1;
	}

	this->_unserialize_header(reinterpret_cast<const uint8_t*>(value.data()), value.size(), e);
	e.key = key;

	return 0;
}
// }}}

// {{{ master identity token
/**
 * Load the persisted master identity token, or generate and persist a new
 * one if the database has never had a token. Called from open() after the
 * RocksDB handle is ready and before the storage is announced as open, so
 * that `get_master_id()` is always meaningful for a successfully-opened DB.
 */
int storage_rocksdb::_load_or_generate_master_id() {
	string value;
	rocksdb::Status status = this->_db->Get(this->_read_options, kReplMasterIdKey, &value);
	if (status.ok()) {
		pthread_rwlock_wrlock(&this->_mutex_master_id);
		this->_master_id = value;
		pthread_rwlock_unlock(&this->_mutex_master_id);
		log_debug("loaded existing master id (id=%s)", value.c_str());
		return 0;
	}
	if (!status.IsNotFound()) {
		log_err("failed to read master id: %s", status.ToString().c_str());
		return -1;
	}

	// Generate a fresh token. We bypass _write_options.sync deliberately
	// here: the token is durable enough as long as the DB survives, and a
	// regenerated token on a crash-during-first-boot is indistinguishable
	// from a fresh DB, which is safe.
	uuid_t uuid;
	char buf[37];
	uuid_generate(uuid);
	uuid_unparse_lower(uuid, buf);
	string new_id = buf;

	rocksdb::WriteOptions wo;
	wo.sync = true;  // first-time token creation IS durable
	wo.disableWAL = false;
	status = this->_db->Put(wo, kReplMasterIdKey, new_id);
	if (!status.ok()) {
		log_err("failed to persist master id: %s", status.ToString().c_str());
		return -1;
	}
	pthread_rwlock_wrlock(&this->_mutex_master_id);
	this->_master_id = new_id;
	pthread_rwlock_unlock(&this->_mutex_master_id);
	log_notice("generated new master id (id=%s)", new_id.c_str());
	return 0;
}

string storage_rocksdb::get_master_id() const {
	pthread_rwlock_rdlock(&this->_mutex_master_id);
	string id = this->_master_id;
	pthread_rwlock_unlock(&this->_mutex_master_id);
	return id;
}

int storage_rocksdb::set_master_id(const string& id) {
	if (id.empty()) {
		log_err("refusing to set empty master id", 0);
		return -1;
	}
	if (this->_db == NULL) {
		log_err("set_master_id: DB handle is closed (failed reopen)", 0);
		return -1;
	}
	rocksdb::WriteOptions wo;
	wo.sync = true;
	wo.disableWAL = false;
	rocksdb::Status status = this->_db->Put(wo, kReplMasterIdKey, id);
	if (!status.ok()) {
		log_err("failed to persist master id: %s", status.ToString().c_str());
		return -1;
	}
	pthread_rwlock_wrlock(&this->_mutex_master_id);
	string old_id = this->_master_id;
	this->_master_id = id;
	pthread_rwlock_unlock(&this->_mutex_master_id);
	log_notice("master id updated (old=%s, new=%s)", old_id.c_str(), id.c_str());
	return 0;
}

int storage_rocksdb::_persist_generation(const char* key, const string& value) {
	if (this->_db == NULL) {
		log_err("_persist_generation: DB handle is closed", 0);
		return -1;
	}
	rocksdb::WriteOptions wo;
	wo.sync = true;			// a generation must never be lost by a crash
	wo.disableWAL = false;
	rocksdb::Status st = this->_db->Put(wo, key, value);
	if (!st.ok()) {
		log_err("failed to persist %s: %s", key, st.ToString().c_str());
		return -1;
	}
	return 0;
}

/**
 *	Mint a generation identity: "<n>:<uuid>".
 *
 *	The uuid is what makes it an IDENTITY. A bare counter is not sufficient:
 *	two copies of the same data promoted one after the other would each
 *	advance their own counter to the same value, so two unrelated sequence
 *	spaces would advertise the same generation and a follower comparing them
 *	would apply one history's numbers against another's. The same argument
 *	applies to a repeated hard reset, which re-initialises a fresh DB every
 *	time. The counter is kept only so a human can see how often it moved; it
 *	is never compared alone.
 */
string storage_rocksdb::_mint_generation(const string& previous) {
	uint64_t n = 0;
	string::size_type colon = previous.find(':');
	if (colon != string::npos) {
		try {
			n = boost::lexical_cast<uint64_t>(previous.substr(0, colon));
		} catch (boost::bad_lexical_cast&) {
			n = 0;
		}
	}
	uuid_t uuid;
	char buf[37];
	uuid_generate(uuid);
	uuid_unparse_lower(uuid, buf);
	return boost::lexical_cast<string>(n + 1) + ":" + buf;
}

/**
 *	Load both generations, minting them on a fresh DB (design §3.1).
 *	A plain process restart keeps both values, which is the point: a restart
 *	is not a history change and must not cost a rebuild.
 */
int storage_rocksdb::_load_or_init_generations() {
	struct { const char* key; string* slot; } gens[] = {
		{ kReplSourceEpochKey, &this->_source_epoch },
		{ kReplIncarnationKey, &this->_incarnation },
	};
	pthread_rwlock_wrlock(&this->_mutex_generations);
	int rc = 0;
	bool minted_epoch_now = false;
	for (size_t i = 0; i < sizeof(gens) / sizeof(gens[0]); i++) {
		string value;
		rocksdb::Status st = this->_db->Get(this->_read_options, gens[i].key, &value);
		if (st.ok() && !value.empty()) {
			*gens[i].slot = value;
			continue;
		}
		if (!st.ok() && !st.IsNotFound()) {
			log_err("failed to read %s: %s", gens[i].key, st.ToString().c_str());
			rc = -1;
			break;
		}
		const string minted = _mint_generation("");
		if (this->_persist_generation(gens[i].key, minted) < 0) {
			rc = -1;
			break;
		}
		*gens[i].slot = minted;
		if (gens[i].slot == &this->_source_epoch) {
			minted_epoch_now = true;
		}
	}
	// The epoch's reason: read it back; a freshly minted epoch on a new DB is
	// "new"; an epoch from before reasons were recorded stays unknown.
	if (rc == 0) {
		string why;
		rocksdb::Status rs = this->_db->Get(this->_read_options, kReplSourceEpochReasonKey, &why);
		if (rs.ok()) {
			this->_source_epoch_reason = why;
		} else if (rs.IsNotFound() && minted_epoch_now) {
			if (this->_persist_generation(kReplSourceEpochReasonKey, "new") == 0) {
				this->_source_epoch_reason = "new";
			}
		} else {
			this->_source_epoch_reason = "";
		}
	}
	// Rebuild evidence: absent or malformed = none (never guessed). It is
	// valid only while this node's own epoch is the one it was recorded
	// under: every change of the local history advances that epoch first, so
	// evidence whose delete was lost cannot come back after a restart.
	if (rc == 0) {
		this->_rebuilt_from_master_id.clear();
		this->_rebuilt_from_epoch.clear();
		string ev;
		rocksdb::Status es = this->_db->Get(this->_read_options, kReplRebuiltFromKey, &ev);
		if (es.ok()) {
			vector<string> parts;
			string::size_type at = 0;
			while (at <= ev.size()) {
				string::size_type sp = ev.find(' ', at);
				if (sp == string::npos) { parts.push_back(ev.substr(at)); break; }
				parts.push_back(ev.substr(at, sp - at));
				at = sp + 1;
			}
			if (parts.size() == 3 && !parts[0].empty() && !parts[1].empty()
					&& parts[2] == this->_source_epoch) {
				this->_rebuilt_from_master_id = parts[0];
				this->_rebuilt_from_epoch = parts[1];
			} else {
				log_notice("rebuild evidence ignored: recorded under another local history or malformed [%s]", ev.c_str());
			}
		}
		this->_suspended_from_master_id.clear();
		this->_suspended_from_epoch.clear();
		string sv;
		rocksdb::Status ss = this->_db->Get(this->_read_options, kReplRebuiltFromSuspendedKey, &sv);
		if (ss.ok()) {
			vector<string> parts;
			string::size_type at = 0;
			while (at <= sv.size()) {
				string::size_type sp = sv.find(' ', at);
				if (sp == string::npos) { parts.push_back(sv.substr(at)); break; }
				parts.push_back(sv.substr(at, sp - at));
				at = sp + 1;
			}
			// valid only under the local history it was recorded under: a
			// truncate / swap / promotion advanced that history and the
			// stored copy is no longer the one it describes
			if (parts.size() == 3 && !parts[0].empty() && !parts[1].empty()
					&& parts[2] == this->_source_epoch) {
				this->_suspended_from_master_id = parts[0];
				this->_suspended_from_epoch = parts[1];
				log_notice("suspended rebuild evidence of the stored copy restored (rebuild in progress): master_id=%s, source epoch %s", parts[0].c_str(), parts[1].c_str());
			} else {
				log_notice("suspended rebuild evidence ignored: recorded under another local history or malformed [%s]", sv.c_str());
			}
		}
	}
	this->_generations_broken = (rc != 0);
	const string epoch = this->_source_epoch;
	const string incarnation = this->_incarnation;
	pthread_rwlock_unlock(&this->_mutex_generations);
	if (rc != 0) {
		log_err("replication generations UNAVAILABLE: this node will neither serve nor accept replication until they can be established", 0);
		return -1;
	}
	log_notice("replication generations (source_epoch=%s, incarnation=%s)",
		epoch.c_str(), incarnation.c_str());
	return 0;
}

string storage_rocksdb::get_source_epoch() {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	string v = this->_generations_broken ? string("") : this->_source_epoch;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return v;
}

string storage_rocksdb::get_source_epoch_reason() {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	string v = this->_generations_broken ? string("") : this->_source_epoch_reason;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return v;
}

string storage_rocksdb::get_rebuilt_from_master_id() {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	string v = this->_generations_broken ? string("") : this->_rebuilt_from_master_id;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return v;
}

string storage_rocksdb::get_rebuilt_from_epoch() {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	string v = this->_generations_broken ? string("") : this->_rebuilt_from_epoch;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return v;
}

/**
 *	Durably remove the rebuild evidence. The in-memory copy is dropped FIRST
 *	so a failed delete never leaves this process advertising evidence for a
 *	copy that is about to change; the caller must not rebuild if this fails
 *	(the persisted evidence would survive a crash mid-rebuild).
 */
int storage_rocksdb::_clear_rebuilt_from_locked() {
	this->_rebuilt_from_master_id.clear();
	this->_rebuilt_from_epoch.clear();
	this->_suspended_from_master_id.clear();
	this->_suspended_from_epoch.clear();
	if (this->_db == NULL) {
		return -1;
	}
	rocksdb::WriteOptions wo;
	wo.sync = true;
	rocksdb::WriteBatch wb;
	wb.Delete(kReplRebuiltFromKey);
	wb.Delete(kReplRebuiltFromSuspendedKey);
	rocksdb::Status st = this->_db->Write(wo, &wb);
	if (!st.ok()) {
		log_err("failed to clear the rebuild evidence: %s", st.ToString().c_str());
		return -1;
	}
	return 0;
}

int storage_rocksdb::clear_rebuilt_from() {
	pthread_rwlock_wrlock(&this->_mutex_generations);
	int r = this->_clear_rebuilt_from_locked();
	pthread_rwlock_unlock(&this->_mutex_generations);
	return r;
}


string storage_rocksdb::get_copy_id() {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	string v = this->_copy_id;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return v;
}

bool storage_rocksdb::copy_identity_consistent() {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	bool b = this->_copy_identity_consistent;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return b;
}

int storage_rocksdb::new_copy_identity(const char* why) {
	uuid_t uuid;
	char buf[37];
	uuid_generate(uuid);
	uuid_unparse_lower(uuid, buf);
	const string id = string(buf) + ":1";
	pthread_rwlock_wrlock(&this->_mutex_generations);
	int r = this->_persist_generation(kCopyIdKey, id);
	if (r == 0) {
		this->_copy_id = id;
	}
	pthread_rwlock_unlock(&this->_mutex_generations);
	if (r == 0) {
		r = copy_fs::write_file_durable(this->_data_path, copy_fs::kCopyIdFile, id);
		log_notice("copy identity: %s (%s)", id.c_str(), why);
	}
	pthread_rwlock_wrlock(&this->_mutex_generations);
	this->_copy_identity_consistent = (r == 0);
	pthread_rwlock_unlock(&this->_mutex_generations);
	return r;
}

int storage_rocksdb::bump_copy_generation(const char* why) {
	pthread_rwlock_wrlock(&this->_mutex_generations);
	string id = this->_copy_id;
	const size_t c = id.rfind(':');
	unsigned long long g = 0;
	if (c != string::npos) {
		g = strtoull(id.c_str() + c + 1, NULL, 10);
	}
	const string next = (c == string::npos ? id : id.substr(0, c)) + ":" + boost::lexical_cast<string>(g + 1);
	int r = id.empty() ? -1 : this->_persist_generation(kCopyIdKey, next);
	if (r == 0) {
		this->_copy_id = next;
	}
	pthread_rwlock_unlock(&this->_mutex_generations);
	if (id.empty()) {
		return this->new_copy_identity(why);
	}
	if (r == 0) {
		r = copy_fs::write_file_durable(this->_data_path, copy_fs::kCopyIdFile, next);
		log_notice("copy identity: %s (generation bumped: %s)", next.c_str(), why);
	}
	pthread_rwlock_wrlock(&this->_mutex_generations);
	this->_copy_identity_consistent = (r == 0);
	pthread_rwlock_unlock(&this->_mutex_generations);
	return r;
}

int storage_rocksdb::switch_to_staging(const string& attempt, const string& expected_new_id) {
	const string staging = this->_data_dir + "/" + copy_fs::kStagingPrefix + attempt;
	if (copy_fs::read_copy_id(staging) != expected_new_id) {
		log_err("switch refused: staging [%s] is not copy %s (found %s)", staging.c_str(), expected_new_id.c_str(),
			copy_fs::read_copy_id(staging).c_str());
		return -1;
	}
	switch_intent in;
	in.attempt = attempt;
	in.old_id = this->get_copy_id();
	in.new_id = expected_new_id;
	if (in.old_id.empty()) {
		ostringstream u;
		u << "unidentified-" << time(NULL) << "-" << getpid();
		in.old_id = u.str();
	}
	// A live copy whose identity records disagree (or has no COPY_ID: a
	// restore that left no marker) is exactly what a verified rebuild
	// replaces. Name it on disk first, so the switch and its crash recovery
	// identify it (CI 37578618876 backup-restore: 'live ?' refused forever).
	if (copy_fs::read_copy_id(this->_data_path) != in.old_id) {
		log_warning("copy switch: the live copy's COPY_ID file does not name %s (identity inconsistent); naming it before it is retained", in.old_id.c_str());
		if (copy_fs::write_file_durable(this->_data_path, copy_fs::kCopyIdFile, in.old_id) < 0) {
			return -1;
		}
	}
	pthread_rwlock_wrlock(&this->_mutex_wholelock);
	int r = -1;
	do {
		if (this->_db != NULL) {
			this->_close_db();		// the live copy is durable once closed
		}
		if (copy_fs::switch_dirs(this->_data_dir, "flare.rocksdb", in) < 0) {
			string report;
			copy_fs::recover(this->_data_dir, "flare.rocksdb", report);
			log_err("copy switch failed; recovery: %s", report.c_str());
			this->_open_db(this->_data_path);
			break;
		}
		rocksdb::Status st = this->_open_db(this->_data_path);
		if (!st.ok()) {
			log_err("copy switch: the new live copy does not open: %s (intent kept: the next open resolves it)", st.ToString().c_str());
			this->_db = NULL;
			break;
		}
		string v;
		rocksdb::Status cs = this->_db->Get(this->_read_options, kCopyIdKey, &v);
		if (!cs.ok() || v != expected_new_id) {
			log_err("copy switch: the opened live copy is %s, not %s (intent kept)", v.c_str(), expected_new_id.c_str());
			break;
		}
		this->_copy_id = v;
		{
			string f;
			this->_copy_identity_consistent = copy_fs::read_small_file(this->_data_path + "/" + copy_fs::kCopyIdFile, f) == 0 && f == v;
		}
		this->_clear_header_cache();
		if (this->_load_or_init_generations() < 0) {
			log_err("copy switch: generations of the new live copy could not be loaded", 0);
		}
		{
			string mid;
			if (this->_db->Get(this->_read_options, kReplMasterIdKey, &mid).ok() && !mid.empty()) {
				pthread_rwlock_wrlock(&this->_mutex_master_id);
				this->_master_id = mid;
				pthread_rwlock_unlock(&this->_mutex_master_id);
			}
		}
		this->_tombstone_sweep_cursor.clear();
		this->_seed_curr_items_by_scan("copy switch");
		this->_quarantined = this->_quarantined_now();
		// the latch described the old copy
		this->_corrupted = false;
		if (copy_fs::remove_intent(this->_data_dir) < 0) {
			break;
		}
		log_notice("copy switch DONE: live is copy %s; the old copy %s is retained as %s%s", v.c_str(), in.old_id.c_str(),
			copy_fs::kRetainedPrefix, attempt.c_str());
		r = 0;
	} while (false);
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return r;
}

void storage_rocksdb::_seed_curr_items_by_scan(const char* why) {
	uint64_t exact = 0;
	rocksdb::ReadOptions ro = this->_read_options;
	ro.fill_cache = false;
	rocksdb::Iterator* it = this->_db->NewIterator(ro);
	for (it->SeekToFirst(); it->Valid(); it->Next()) {
		if (!is_reserved_key(it->key().ToString())) {
			exact++;
		}
	}
	const bool ok = it->status().ok();
	delete it;
	this->_curr_items.sub(this->_curr_items.fetch());
	if (ok && exact > 0) {
		this->_curr_items.add(exact);
	}
	log_notice("curr_items seeded by an exact scan (%s): %llu live key(s)%s", why, (unsigned long long)exact, ok ? "" : " (scan FAILED -> 0)");
}

void storage_rocksdb::set_rebuild_blocked(const string& why) {
	pthread_mutex_lock(&this->_mutex_rebuild_status);
	this->_rebuild_blocked = why;
	pthread_mutex_unlock(&this->_mutex_rebuild_status);
}

string storage_rocksdb::get_rebuild_blocked() {
	pthread_mutex_lock(&this->_mutex_rebuild_status);
	string v = this->_rebuild_blocked;
	pthread_mutex_unlock(&this->_mutex_rebuild_status);
	return v;
}

void storage_rocksdb::note_staged_result(bool switched) {
	pthread_mutex_lock(&this->_mutex_rebuild_status);
	if (switched) this->_staged_switched++; else this->_staged_abandoned++;
	pthread_mutex_unlock(&this->_mutex_rebuild_status);
}

uint64_t storage_rocksdb::get_staged_switched() {
	pthread_mutex_lock(&this->_mutex_rebuild_status);
	uint64_t v = this->_staged_switched;
	pthread_mutex_unlock(&this->_mutex_rebuild_status);
	return v;
}

uint64_t storage_rocksdb::get_staged_abandoned() {
	pthread_mutex_lock(&this->_mutex_rebuild_status);
	uint64_t v = this->_staged_abandoned;
	pthread_mutex_unlock(&this->_mutex_rebuild_status);
	return v;
}

string storage_rocksdb::new_attempt_id() {
	uuid_t uuid;
	char buf[37];
	uuid_generate(uuid);
	uuid_unparse_lower(uuid, buf);
	// short and filesystem-safe; unique enough per data_dir
	return string(buf).substr(0, 8) + string(buf).substr(9, 4);
}

int storage_rocksdb::make_staging_dir(const string& attempt, string& path) {
	if (this->_staging || attempt.empty() || attempt.find('/') != string::npos) {
		return -1;
	}
	path = this->_data_dir + "/" + copy_fs::kStagingPrefix + attempt;
	if (copy_fs::dir_exists(path)) {
		log_err("staging: [%s] already exists; refusing to reuse it", path.c_str());
		return -1;
	}
	if (mkdir(path.c_str(), 0700) != 0) {
		log_err("staging: cannot create [%s]: %s", path.c_str(), util::strerror(errno));
		return -1;
	}
	if (!copy_fs::same_device(this->_data_dir, path)) {
		log_err("staging: [%s] is not on the data dir's filesystem (the switch would not be atomic)", path.c_str());
		copy_fs::remove_tree_path(path);
		return -1;
	}
	return copy_fs::fsync_dir(this->_data_dir);
}

storage_rocksdb* storage_rocksdb::open_staging(const string& attempt, bool existing_files) {
	if (this->_staging || attempt.empty() || attempt.find('/') != string::npos) {
		return NULL;
	}
	string path = this->_data_dir + "/" + copy_fs::kStagingPrefix + attempt;
	if (!existing_files) {
		if (this->make_staging_dir(attempt, path) < 0) {
			return NULL;
		}
	} else if (!copy_fs::dir_exists(path) || !copy_fs::same_device(this->_data_dir, path)) {
		log_err("staging: [%s] does not exist or is not on the data dir's filesystem", path.c_str());
		return NULL;
	}
	// A small cache and write buffer: the staging copy is written, not
	// served, and on tmpfs its memory counts against the pod as well.
	storage_rocksdb* s = new storage_rocksdb(this->_data_dir, this->_mutex_slot_size, this->_header_cache_size,
		8, std::min<uint64_t>(this->_write_buffer_size_mb, 32), 2,
		this->_wal_ttl_seconds, this->_wal_size_limit_mb, false);
	s->_staging = true;
	s->_data_path = path;
	if (s->open() < 0) {
		log_err("staging: the copy at [%s] does not open", path.c_str());
		delete s;
		return NULL;
	}
	log_notice("staging copy opened at [%s] (copy %s, %s)", path.c_str(), s->get_copy_id().c_str(),
		existing_files ? "received files" : "new and empty");
	return s;
}

int storage_rocksdb::adopt_history(const string& master_id, const string& epoch, uint64_t cursor) {
	if (!this->_staging || this->_db == NULL || master_id.empty()) {
		return -1;
	}
	const string adopted = epoch.empty() ? this->get_source_epoch() : epoch;
	if (adopted.empty()) {
		return -1;
	}
	pthread_rwlock_wrlock(&this->_mutex_wholelock);
	int r = -1;
	do {
		// inherited replication metadata (a checkpoint carries the source's)
		// is expressed in another sequence space: start from an empty family
		if (this->_cf_meta != NULL) {
			rocksdb::Status ds = this->_db->DropColumnFamily(this->_cf_meta);
			this->_db->DestroyColumnFamilyHandle(this->_cf_meta);
			this->_cf_meta = NULL;
			if (!ds.ok()) {
				log_err("staging: could not drop the inherited replication metadata: %s", ds.ToString().c_str());
				break;
			}
		}
		rocksdb::ColumnFamilyHandle* fresh = NULL;
		rocksdb::Status cs = this->_db->CreateColumnFamily(rocksdb::ColumnFamilyOptions(this->_options), kReplMetaCfName, &fresh);
		if (!cs.ok()) {
			log_err("staging: could not recreate the replication metadata family: %s", cs.ToString().c_str());
			break;
		}
		this->_cf_meta = fresh;
		this->_tombstone_sweep_cursor.clear();
		const string next_incarnation = _mint_generation(this->get_incarnation());
		rocksdb::WriteBatch b;
		b.Put(kReplMasterIdKey, master_id);
		b.Put(kReplLastLsnKey, boost::lexical_cast<string>(cursor));
		b.Put(kReplSourceEpochKey, adopted);
		b.Put(kReplSourceEpochReasonKey, epoch.empty() ? "new" : "inherited");
		b.Put(kReplIncarnationKey, next_incarnation);
		b.Delete(kReplRebuiltFromKey);
		b.Delete(kReplRebuiltFromSuspendedKey);
		b.Delete(kReplRestoreDoneKey);
		rocksdb::WriteOptions wo;
		wo.sync = true;
		rocksdb::Status st = this->_db->Write(wo, &b);
		if (!st.ok()) {
			log_err("staging: could not record the adopted history: %s", st.ToString().c_str());
			break;
		}
		pthread_rwlock_wrlock(&this->_mutex_master_id);
		this->_master_id = master_id;
		pthread_rwlock_unlock(&this->_mutex_master_id);
		pthread_rwlock_wrlock(&this->_mutex_generations);
		this->_source_epoch = adopted;
		this->_source_epoch_reason = epoch.empty() ? "new" : "inherited";
		this->_incarnation = next_incarnation;
		this->_rebuilt_from_master_id.clear();
		this->_rebuilt_from_epoch.clear();
		this->_suspended_from_master_id.clear();
		this->_suspended_from_epoch.clear();
		this->_generations_broken = false;
		pthread_rwlock_unlock(&this->_mutex_generations);
		r = 0;
	} while (false);
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	if (r == 0) {
		this->_seed_curr_items_by_scan("staging adopted a history");
		log_notice("staging copy %s follows master_id %s, source epoch %s from %llu", this->get_copy_id().c_str(),
			master_id.c_str(), epoch.empty() ? "(none: legacy source; own epoch kept)" : epoch.c_str(), (unsigned long long)cursor);
	}
	return r;
}

int storage_rocksdb::seal() {
	if (!this->_staging || this->_db == NULL) {
		return -1;
	}
	rocksdb::FlushOptions fo;
	fo.wait = true;
	rocksdb::Status f1 = this->_db->Flush(fo, this->_cf_default);
	rocksdb::Status f2 = this->_cf_meta != NULL ? this->_db->Flush(fo, this->_cf_meta) : rocksdb::Status::OK();
	rocksdb::Status w = this->_db->FlushWAL(true);
	if (!f1.ok() || !f2.ok() || !w.ok()) {
		log_err("staging: the copy could not be made durable (flush %s / %s, wal %s)", f1.ToString().c_str(),
			f2.ToString().c_str(), w.ToString().c_str());
		return -1;
	}
	this->close();
	if (copy_fs::fsync_dir(this->_data_path) < 0 || copy_fs::fsync_dir(this->_data_dir) < 0) {
		return -1;
	}
	return 0;
}

int storage_rocksdb::remove_staging(const string& attempt) {
	if (attempt.empty() || attempt.find('/') != string::npos) {
		return -1;
	}
	const string path = this->_data_dir + "/" + copy_fs::kStagingPrefix + attempt;
	if (copy_fs::remove_tree_path(path) != 0) {
		log_err("staging: could not remove [%s]", path.c_str());
		return -1;
	}
	copy_fs::fsync_dir(this->_data_dir);
	log_notice("staging copy [%s] removed (attempt abandoned; the live copy is unchanged)", path.c_str());
	return 0;
}

int storage_rocksdb::record_retained(const string& attempt, const string& master_id, const string& epoch) {
	const string dir = this->_data_dir + "/" + copy_fs::kRetainedPrefix + attempt;
	if (!copy_fs::dir_exists(dir) || master_id.empty() || epoch.empty()) {
		return -1;
	}
	return copy_fs::write_file_durable(dir, copy_fs::kRetainedRecordFile,
		this->get_copy_id() + " " + master_id + " " + epoch);
}

vector<string> storage_rocksdb::list_retained() {
	vector<string> out;
	DIR* d = opendir(this->_data_dir.c_str());
	if (d == NULL) {
		return out;
	}
	struct dirent* e;
	const size_t plen = strlen(copy_fs::kRetainedPrefix);
	while ((e = readdir(d)) != NULL) {
		const string n = e->d_name;
		if (n.size() > plen && n.compare(0, plen, copy_fs::kRetainedPrefix) == 0
				&& copy_fs::dir_exists(this->_data_dir + "/" + n)) {
			out.push_back(n.substr(plen));
		}
	}
	closedir(d);
	return out;
}

int storage_rocksdb::reap_retained(const string& bound_master_id, const string& bound_epoch, bool bound_eligible, bool own_active, string& report) {
	report.clear();
	int removed = 0;
	const vector<string> attempts = this->list_retained();
	for (size_t i = 0; i < attempts.size(); i++) {
		const string dir = this->_data_dir + "/" + copy_fs::kRetainedPrefix + attempts[i];
		string text;
		retained_record rec;
		const bool has = copy_fs::read_small_file(dir + "/" + copy_fs::kRetainedRecordFile, text) == 0
			&& parse_retained_record(text, rec);
		string why;
		if (!retained_deletable(has, rec, this->get_copy_id(), this->copy_identity_consistent(),
				bound_master_id, bound_epoch, bound_eligible, own_active, why)) {
			report += (report.empty() ? "" : "; ") + attempts[i] + " kept: " + why;
			continue;
		}
		// the live copy is a verified replacement that is bound and Active:
		// a quarantine marker no longer describes it (removed BEFORE the
		// retained copy goes, so a crash never leaves the marker orphaned
		// on a deleted copy's account)
		if (copy_fs::dir_exists(this->_data_dir) && !this->_quarantined_now()) {
			string mt;
			if (copy_fs::read_small_file(this->_data_dir + "/" + kQuarantineMarkerFile, mt) == 0
					&& this->_clear_quarantine_marker("a verified rebuild replaced the post-quarantine copy and is bound and Active") < 0) {
				report += (report.empty() ? "" : "; ") + attempts[i] + " kept: the quarantine marker could not be removed";
				continue;
			}
		}
		if (copy_fs::remove_tree_path(dir) != 0) {
			log_err("retained copy [%s]: deletion failed part-way (what is left stays; checked again)", dir.c_str());
			report += (report.empty() ? "" : "; ") + attempts[i] + " deletion failed";
			continue;
		}
		copy_fs::fsync_dir(this->_data_dir);
		removed++;
		log_notice("retained copy [%s] deleted (%s)", dir.c_str(), why.c_str());
	}
	return removed;
}

int storage_rocksdb::suspend_rebuilt_from() {
	pthread_rwlock_wrlock(&this->_mutex_generations);
	int r = 0;
	const string mid = this->_rebuilt_from_master_id;
	const string ep = this->_rebuilt_from_epoch;
	// the advertised evidence goes FIRST in memory (as clear_rebuilt_from)
	this->_rebuilt_from_master_id.clear();
	this->_rebuilt_from_epoch.clear();
	if (this->_db == NULL) {
		r = -1;
	} else {
		rocksdb::WriteOptions wo;
		wo.sync = true;
		rocksdb::WriteBatch wb;
		wb.Delete(kReplRebuiltFromKey);
		if (!mid.empty() && !ep.empty() && !this->_source_epoch.empty()) {
			// atomically: advertised -> suspended (same format and binding)
			wb.Put(kReplRebuiltFromSuspendedKey, mid + " " + ep + " " + this->_source_epoch);
		}
		rocksdb::Status st = this->_db->Write(wo, &wb);
		if (!st.ok()) {
			log_err("failed to suspend the rebuild evidence: %s", st.ToString().c_str());
			r = -1;
		} else if (!mid.empty() && !ep.empty()) {
			this->_suspended_from_master_id = mid;
			this->_suspended_from_epoch = ep;
		}
		// with no advertised evidence, an earlier attempt's suspended record
		// (same stored copy, same local history) stays as it is
	}
	pthread_rwlock_unlock(&this->_mutex_generations);
	return r;
}

int storage_rocksdb::clear_suspended_rebuilt_from() {
	pthread_rwlock_wrlock(&this->_mutex_generations);
	this->_suspended_from_master_id.clear();
	this->_suspended_from_epoch.clear();
	int r = -1;
	if (this->_db != NULL) {
		rocksdb::WriteOptions wo;
		wo.sync = true;
		rocksdb::Status st = this->_db->Delete(wo, kReplRebuiltFromSuspendedKey);
		r = st.ok() ? 0 : -1;
		if (!st.ok()) log_err("failed to clear the suspended rebuild evidence: %s", st.ToString().c_str());
	}
	pthread_rwlock_unlock(&this->_mutex_generations);
	return r;
}

string storage_rocksdb::get_suspended_rebuilt_from_master_id() {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	string v = this->_generations_broken ? string("") : this->_suspended_from_master_id;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return v;
}

string storage_rocksdb::get_suspended_rebuilt_from_epoch() {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	string v = this->_generations_broken ? string("") : this->_suspended_from_epoch;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return v;
}

int storage_rocksdb::set_rebuilt_from(const string& master_id, const string& epoch) {
	if (master_id.empty() || epoch.empty()
			|| master_id.find(' ') != string::npos || epoch.find(' ') != string::npos) {
		return -1;
	}
	pthread_rwlock_wrlock(&this->_mutex_generations);
	int r = (this->_generations_broken || this->_source_epoch.empty()) ? -1
		: this->_persist_generation(kReplRebuiltFromKey, master_id + " " + epoch + " " + this->_source_epoch);
	if (r == 0) {
		this->_rebuilt_from_master_id = master_id;
		this->_rebuilt_from_epoch = epoch;
		// the stored copy is now the one this evidence describes
		this->_suspended_from_master_id.clear();
		this->_suspended_from_epoch.clear();
		if (this->_db != NULL) {
			rocksdb::WriteOptions wo;
			wo.sync = true;
			this->_db->Delete(wo, kReplRebuiltFromSuspendedKey);
		}
	}
	pthread_rwlock_unlock(&this->_mutex_generations);
	if (r == 0) {
		log_notice("rebuild evidence recorded: this copy was rebuilt by a full dump from master_id=%s, source epoch %s (evidence of the history, not of a replication position)", master_id.c_str(), epoch.c_str());
	}
	return r;
}

bool storage_rocksdb::rebuild_evidence_valid(bool truncated, bool dump_ok,
		const string& start_master_id, const string& start_epoch,
		const string& end_master_id, const string& end_epoch) {
	return truncated && dump_ok
		&& !start_master_id.empty() && !start_epoch.empty()
		&& start_master_id == end_master_id && start_epoch == end_epoch;
}

string storage_rocksdb::get_incarnation() {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	string v = this->_generations_broken ? string("") : this->_incarnation;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return v;
}

bool storage_rocksdb::generations_broken() const {
	pthread_rwlock_rdlock(&this->_mutex_generations);
	bool b = this->_generations_broken;
	pthread_rwlock_unlock(&this->_mutex_generations);
	return b;
}

/**
 *	Advance the SOURCE EPOCH: this node's history is no longer a continuation
 *	of what followers have been reading. Promotion, a replacement of the local
 *	history, and a bulk rewrite (truncate / flush_all) all qualify. Followers
 *	see a different identity, refuse the old stream and rebuild.
 *
 *	FAIL CLOSED: if the new identity cannot be persisted, the node must not
 *	keep advertising the old one over a changed history. The generations go
 *	UNAVAILABLE, which every replication path refuses on.
 */
int storage_rocksdb::advance_source_epoch(const char* reason) {
	pthread_rwlock_wrlock(&this->_mutex_generations);
	const string minted = _mint_generation(this->_source_epoch);
	int r = this->_persist_generation(kReplSourceEpochKey, minted);
	if (r == 0) {
		this->_source_epoch = minted;
		// This node's own history changed: what it was rebuilt from no
		// longer describes it.
		this->_clear_rebuilt_from_locked();
		// The reason is evidence, not identity: if it cannot be persisted it is
		// left UNKNOWN (empty), never guessed, and a repair that needs it defers.
		const string why = reason != NULL ? reason : "";
		if (this->_persist_generation(kReplSourceEpochReasonKey, why) == 0) {
			this->_source_epoch_reason = why;
		} else {
			this->_source_epoch_reason = "";
		}
	} else {
		this->_generations_broken = true;
	}
	pthread_rwlock_unlock(&this->_mutex_generations);
	if (r == 0) {
		log_notice("source epoch advanced to %s (reason: %s; followers of the previous history must rebuild)", minted.c_str(), reason != NULL ? reason : "");
	} else {
		log_err("could not persist the new source epoch: this node's history changed but the identity did not — replication is now UNAVAILABLE here (fail closed)", 0);
	}
	return r;
}

/**
 *	Advance the RECEIVER INCARNATION: this node's own copy was replaced, so
 *	streams and forwarded changes issued against the previous copy must be
 *	refused rather than applied onto the new one. Same fail-closed rule.
 */
int storage_rocksdb::advance_incarnation() {
	pthread_rwlock_wrlock(&this->_mutex_generations);
	const string minted = _mint_generation(this->_incarnation);
	int r = this->_persist_generation(kReplIncarnationKey, minted);
	if (r == 0) {
		this->_incarnation = minted;
	} else {
		this->_generations_broken = true;
	}
	pthread_rwlock_unlock(&this->_mutex_generations);
	if (r == 0) {
		log_notice("receiver incarnation advanced to %s (deliveries for the previous copy are refused)", minted.c_str());
	} else {
		log_err("could not persist the new receiver incarnation: this node's copy was replaced but the identity did not change — replication is now UNAVAILABLE here (fail closed)", 0);
	}
	return r;
}

int storage_rocksdb::regenerate_master_id() {
	// Mint a fresh UUID (same generator as _load_or_generate_master_id) and
	// persist it via set_master_id (durable Put + in-memory swap under
	// _mutex_master_id). Used to deliberately break lineage at promotion so a
	// former master's inflated replication cursor can never be compared, across
	// a discontinuous sequence space, against this node's own sequence.
	uuid_t uuid;
	char buf[37];
	uuid_generate(uuid);
	uuid_unparse_lower(uuid, buf);
	string new_id = buf;
	log_notice("regenerating master id (promotion with inverted replication cursor)", 0);
	return this->set_master_id(new_id);
}
// }}}

// {{{ public methods
/**
 *	Open the DB with the default column family and the replication-metadata
 *	one, creating the latter when the directory predates it. Every open site
 *	goes through here: RocksDB refuses to open a directory whose column
 *	families are not all listed, so a single place has to know about them.
 */
rocksdb::Status storage_rocksdb::_open_db(const string& path) {
	vector<string> existing;
	rocksdb::Status ls = rocksdb::DB::ListColumnFamilies(rocksdb::DBOptions(this->_options), path, &existing);
	bool has_meta = false;
	if (ls.ok()) {
		for (size_t i = 0; i < existing.size(); i++) {
			if (existing[i] == kReplMetaCfName) {
				has_meta = true;
			}
		}
	}

	vector<rocksdb::ColumnFamilyDescriptor> descriptors;
	descriptors.push_back(rocksdb::ColumnFamilyDescriptor(
		rocksdb::kDefaultColumnFamilyName, rocksdb::ColumnFamilyOptions(this->_options)));
	if (has_meta) {
		descriptors.push_back(rocksdb::ColumnFamilyDescriptor(
			kReplMetaCfName, rocksdb::ColumnFamilyOptions(this->_options)));
	}

	vector<rocksdb::ColumnFamilyHandle*> handles;
	rocksdb::Status st = rocksdb::DB::Open(rocksdb::DBOptions(this->_options), path, descriptors, &handles, &this->_db);
	if (!st.ok()) {
		return st;
	}
	this->_cf_default = handles[0];
	this->_cf_meta = NULL;
	if (has_meta) {
		this->_cf_meta = handles[1];
	} else {
		rocksdb::ColumnFamilyHandle* cf = NULL;
		rocksdb::Status cs = this->_db->CreateColumnFamily(
			rocksdb::ColumnFamilyOptions(this->_options), kReplMetaCfName, &cf);
		if (!cs.ok()) {
			log_err("failed to create the replication metadata column family: %s", cs.ToString().c_str());
			return cs;
		}
		this->_cf_meta = cf;
	}
	return rocksdb::Status::OK();
}

void storage_rocksdb::_close_db() {
	if (this->_db != NULL) {
		if (this->_cf_meta != NULL) {
			this->_db->DestroyColumnFamilyHandle(this->_cf_meta);
			this->_cf_meta = NULL;
		}
		if (this->_cf_default != NULL) {
			this->_db->DestroyColumnFamilyHandle(this->_cf_default);
			this->_cf_default = NULL;
		}
		delete this->_db;
		this->_db = NULL;
	}
}

int storage_rocksdb::open() {
	if (this->_open) {
		log_warning("storage has been already opened", 0);
		return -1;
	}

	// Copy retention (design §4.2): resolve an interrupted switch from what
	// exists on disk BEFORE the live DB is opened; only then remove the
	// unfinished staging copies.
	if (!this->_staging && copy_fs::dir_exists(this->_data_dir)) {
		string report;
		if (copy_fs::recover(this->_data_dir, "flare.rocksdb", report) < 0) {
			log_err("storage open refused: the copy switch could not be resolved (%s)", report.c_str());
			return -1;
		}
		copy_fs::cleanup_staging(this->_data_dir);
		// no transfer of the previous process survives it: its serve and
		// receive areas are removed (design §5)
		copy_fs::remove_prefixed(this->_data_dir, "snapshot.serve.");
		copy_fs::remove_prefixed(this->_data_dir, "snapshot.recv.");
	}

	// Never expose a half-restored copy (design §3.9(D)).
	if (!this->_staging && this->_discard_incomplete_restore() < 0) {
		log_err("storage open refused: an interrupted restore could not be cleaned up", 0);
		return -1;
	}

	rocksdb::Status status = this->_open_db(this->_data_path);
	if (!status.ok()) {
		log_err("RocksDB::Open() failed: %s", status.ToString().c_str());
		this->_close_db();
		return -1;
	}

	// Seed the O(1) curr_items counter (see storage_rocksdb.h) with an EXACT
	// scan of the data family. This used to read rocksdb.estimate-num-keys,
	// which does not see keys that live only in the WAL: after a crash (or
	// any reopen with an unflushed tail) the recovered keys were missing from
	// the count, so curr_items under-reported by exactly the unflushed
	// writes (observed by the SAF-10d crash test: 52 keys present, not
	// counted, and every count-based comparison — replica divergence,
	// empty-master guard, the acceptance suite — read it as data loss).
	// The scan is O(n) at boot only (fill_cache=false), the same routine a
	// snapshot swap already runs on a full copy; its duration is logged.
	{
		struct timeval t0, t1;
		gettimeofday(&t0, NULL);
		uint64_t exact = 0;
		rocksdb::ReadOptions ro = this->_read_options;
		ro.fill_cache = false;
		rocksdb::Iterator* it = this->_db->NewIterator(ro);
		for (it->SeekToFirst(); it->Valid(); it->Next()) {
			if (!is_reserved_key(it->key().ToString())) {
				exact++;
			}
		}
		const bool scan_ok = it->status().ok();
		delete it;
		gettimeofday(&t1, NULL);
		const long ms = (t1.tv_sec - t0.tv_sec) * 1000L + (t1.tv_usec - t0.tv_usec) / 1000L;
		if (!scan_ok) {
			log_warning("curr_items seed: the open-time key scan failed (%s) -> seeding 0; the count is rebuilt by writes only", it == NULL ? "" : "iterator error");
			exact = 0;
		} else {
			log_notice("curr_items seeded by an exact scan: %llu live key(s) in %ld ms", (unsigned long long)exact, ms);
		}
		this->_curr_items.sub(this->_curr_items.fetch());
		if (exact > 0) {
			this->_curr_items.add(exact);
		}
	}

	// A staging copy made from received checkpoint files: what history do
	// those files carry? Read BEFORE generations are initialised (that would
	// mint one for a copy that has none).
	if (this->_staging) {
		string e;
		rocksdb::Status es = this->_db->Get(this->_read_options, kReplSourceEpochKey, &e);
		this->_staging_found_epoch = es.ok() ? e : string("");
	}

	// Establish this DB's master identity token. Must succeed; otherwise
	// the WAL replication subsystem cannot detect cross-lineage sync
	// attempts, so we fail closed.
	if (this->_load_or_generate_master_id() < 0) {
		this->_close_db();
		return -1;
	}
	if (this->_load_or_init_generations() < 0) {
		log_err("failed to initialise replication generations", 0);
		return -1;
	}
	{
		// the copy identity: load, or mint for a copy that has none yet
		// The two records (reserved key, COPY_ID file) are both updated
		// BEFORE the content changes. A copy whose records disagree (a
		// crash between the two writes) is NOT a normal healthy copy: it is
		// flagged inconsistent until a verified rebuild replaces it.
		string v;
		rocksdb::Status cs = this->_db->Get(this->_read_options, kCopyIdKey, &v);
		string f;
		const bool has_file = copy_fs::read_small_file(this->_data_path + "/" + copy_fs::kCopyIdFile, f) == 0 && !f.empty();
		const bool has_key = cs.ok() && !v.empty();
		const string restored_marker = this->_data_path + "/RESTORED";
		struct stat rst;
		const bool restored = !this->_staging && stat(restored_marker.c_str(), &rst) == 0;
		if (this->_staging) {
			// a staging copy is always a different copy (received checkpoint
			// files carry the SOURCE's key and no COPY_ID file)
			if (this->new_copy_identity("staging copy") < 0) {
				log_err("failed to give the staging copy an identity", 0);
				return -1;
			}
		} else if (restored) {
			// put in place by a restore (backup bootstrap, restore hook): a
			// checkpoint carries the reserved key of the copy it was taken
			// from and no COPY_ID file. It is a DIFFERENT copy: a new
			// identity, then the marker goes (a crash in between mints again)
			if (this->new_copy_identity("restored copy (RESTORED marker)") < 0) {
				log_err("failed to give the restored copy an identity", 0);
				return -1;
			}
			unlink(restored_marker.c_str());
			copy_fs::fsync_dir(this->_data_path);
		} else if (!has_key && !has_file) {
			if (this->new_copy_identity("first open of a copy without an identity") < 0) {
				log_err("failed to initialise the copy identity", 0);
				return -1;
			}
			this->_copy_identity_consistent = true;
		} else if (has_key && has_file && v == f) {
			this->_copy_id = v;
			this->_copy_identity_consistent = true;
		} else {
			this->_copy_id = has_key ? v : f;
			this->_copy_identity_consistent = false;
			log_err("CRITICAL: copy identity INCONSISTENT (reserved key [%s], COPY_ID file [%s]): this copy is not treated as a healthy copy (no approvals, no read binding, not promotable, not a repair source) until a verified rebuild replaces it",
				has_key ? v.c_str() : "(none)", has_file ? f.c_str() : "(none)");
		}
	}

	if (!this->_staging) {
		this->_quarantined = this->_quarantined_now();
		if (this->_quarantined) {
			log_err("CRITICAL: this copy (%s) is the empty copy left by a quarantine (quarantine.marker): it is NOT a healthy copy (no reads, not promotable, not a repair source) until a verified rebuild replaces it", this->get_copy_id().c_str());
		}
	}

	log_notice("storage open (path=%s, type=%s, master_id=%s, sync_writes=%s, wal_ttl=%llus, wal_size_limit=%lluMB)",
		this->_data_path.c_str(), storage::type_cast(this->_type).c_str(), this->get_master_id().c_str(),
		this->_sync_writes ? "true" : "false",
		(unsigned long long)this->_wal_ttl_seconds,
		(unsigned long long)this->_wal_size_limit_mb);
	this->_open = true;

	return 0;
}

int storage_rocksdb::close() {
	if (!this->_open) {
		log_warning("storage is not yet opened", 0);
		return -1;
	}

	// Clean up any active iteration
	if (this->_iter_snapshot) {
		this->iter_end();
	}

	this->_close_db();

	log_debug("storage close", 0);
	this->_open = false;

	return 0;
}

int storage_rocksdb::set(entry& e, result& r, int b) {
	log_info("set (key=%s, flag=%d, expire=%ld, size=%llu, version=%llu, behavior=%x)",
		e.key.c_str(), e.flag, e.expire, e.size, e.version, b);

	// Reject attempts to touch reserved replication metadata keys from
	// any user-visible path. Returning result_not_stored mirrors the
	// semantics clients already see for version conflicts, so existing
	// error-handling in upstream code paths Just Works.
	if (is_reserved_key(e.key)) {
		log_warning("refusing set on reserved key (key=%s)", e.key.c_str());
		r = result_not_stored;
		return 0;
	}

	int mutex_index = 0;
	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	uint8_t* p = NULL;
	try {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_rdlock(&this->_mutex_wholelock);
			pthread_rwlock_wrlock(&this->_mutex_slot[mutex_index]);
		}

		if (this->_db == NULL) {
			// Handle closed by a failed reopen (ENOSPC path) — hard error,
			// never dereference NULL.
			throw -1;
		}

		// get current entry
		entry e_current;
		int e_current_exists = 0;
		if (b & (behavior_append | behavior_prepend | behavior_touch)) {
			result r;
			e_current.key = e.key;
			int n = this->get(e_current, r, behavior_skip_lock);
			if (r == result_not_found || n < 0) {
				this->_get_header_cache(e_current.key, e_current);
				e_current_exists = -1;
			} else {
				e_current_exists = 0;
			}
		} else {
			e_current_exists = this->_get_header(e.key, e_current);
		}

		// determine state
		enum st {
			st_alive,
			st_not_expired,
			st_gone,
		};
		int e_current_st = st_alive;
		if (e_current_exists == 0) {
			if ((b & behavior_skip_timestamp) == 0 && e_current.expire > 0 && e_current.expire <= stats_object->get_timestamp()) {
				e_current_st = st_gone;
			}
		} else {
			if ((b & behavior_skip_timestamp) == 0 && e_current.expire > 0 && e_current.expire > stats_object->get_timestamp()) {
				e_current_st = st_not_expired;
			} else {
				e_current_st = st_gone;
			}
		}

		// check for "add"
		if ((b & behavior_add) != 0 && e_current_st != st_gone) {
			log_debug("behavior=add and data exists (or delete queue not expired) -> skip setting", 0);
			r = result_not_stored;
			throw 0;
		}

		// check for "replace"
		if ((b & behavior_replace) != 0 && e_current_st != st_alive) {
			log_debug("behavior=replace and data not found (or delete queue not expired) -> skip setting", 0);
			r = result_not_stored;
			throw 0;
		}

		// check for "touch" and "gat"
		if ((b & behavior_touch) != 0 && e_current_st != st_alive) {
			log_debug("behavior=touch and data not found (or delete queue not expired) -> skip setting", 0);
			r = result_not_found;
			throw 0;
		}

		// version handling
		if (b & behavior_cas) {
			if (e_current_st == st_gone) {
				log_debug("behavior=cas and data not found -> skip setting", 0);
				r = result_not_found;
				throw 0;
			}
			if (e.version != e_current.version) {
				log_info("behavior=cas and specified version is not equal to current version -> skip setting (current=%llu, specified=%llu)", e_current.version, e.version);
				r = result_exists;
				throw 0;
			}
			e.version++;
		} else if (b & behavior_touch) {
			// touch does not update the version
			e.version = e_current.version;
		} else if ((b & behavior_skip_version) == 0 && e.version != 0) {
			if ((e_current_st == st_alive || (b & behavior_dump) != 0) && e.version <= e_current.version) {
				log_info("specified version is older than (or equal to) current version -> skip setting (current=%llu, specified=%llu)", e_current.version, e.version);
				r = result_not_stored;
				throw 0;
			}
		} else if (e.version == 0) {
			e.version = e_current.version+1;
			log_debug("updating version (version=%llu)", e.version);
		}

		// prepare data for storage
		if (b & (behavior_append | behavior_prepend)) {
			if (e_current_st != st_alive) {
				log_warning("behavior=append|prepend but no data exists -> skip setting", 0);
				throw -1;
			}
			// memcached ignores expire and flag in case of append|prepend
			e.expire = e_current.expire;
			e.flag = e_current.flag;
			p = new uint8_t[entry::header_size + e.size + e_current.size];
			uint64_t e_size = e.size;
			e.size += e_current.size;
			this->_serialize_header(e, p);

			// :(
			if (b & behavior_append) {
				memcpy(p+entry::header_size, e_current.data.get(), e_current.size);
				memcpy(p+entry::header_size+e_current.size, e.data.get(), e_size);
			} else {
				memcpy(p+entry::header_size, e.data.get(), e_size);
				memcpy(p+entry::header_size+e_size, e_current.data.get(), e_current.size);
			}
			shared_byte data(new uint8_t[e.size]);
			memcpy(data.get(), p+entry::header_size, e.size);
			e.data = data;
		} else if (b & behavior_touch) {
			// copy everything except the expiration
			e.flag = e_current.flag;
			e.size = e_current.size;
			e.data = e_current.data;
			p = new uint8_t[entry::header_size + e.size];
			this->_serialize_header(e, p);
			memcpy(p+entry::header_size, e_current.data.get(), e.size);
		} else {
			p = new uint8_t[entry::header_size + e.size];
			this->_serialize_header(e, p);
			memcpy(p+entry::header_size, e.data.get(), e.size);
		}

		// Write to RocksDB
		rocksdb::Slice key_slice(e.key);
		rocksdb::Slice value_slice(reinterpret_cast<char*>(p), entry::header_size + e.size);
		rocksdb::Status status = this->_db->Put(this->_write_options, key_slice, value_slice);

		if (!this->_note_write_status(status, "set")) {
			log_err("RocksDB::Put() failed: %s", status.ToString().c_str());
			r = result_not_stored;
			throw 0;
		}

		r = (b & behavior_touch) ? result_touched : result_stored;
		// ORDER LABEL (design §3.9(B)): read INSIDE the key's critical
		// section. Read after the write and while the slot lock is still
		// held, so the next change to this key — which must take the same
		// lock — is guaranteed a strictly greater value. Reading it after
		// the lock is released is the counterexample that resurrects a
		// deleted key, so this must not be moved into the caller.
		e.seq_label = this->_db->GetLatestSequenceNumber();

		// O(1) curr_items bookkeeping: this Put created a key that was not
		// physically present (e_current_exists reflects a real Get above).
		if (e_current_exists < 0) {
			this->_curr_items.incr();
		}

		delete[] p;
		p = NULL;

	} catch (int e) {
		if (p) {
			delete[] p;
		}
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
			pthread_rwlock_unlock(&this->_mutex_wholelock);
		}
		return e;
	}

	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		pthread_rwlock_unlock(&this->_mutex_wholelock);
	}

	return 0;
}

int storage_rocksdb::get(entry& e, result& r, int b) {
	log_debug("get (key=%s, behavior=%x)", e.key.c_str(), b);

	// Reserved keys are invisible to readers.
	if (is_reserved_key(e.key)) {
		r = result_not_found;
		return 0;
	}

	int mutex_index = 0;
	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	bool expired = false;

	try {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_rdlock(&this->_mutex_wholelock);
			pthread_rwlock_rdlock(&this->_mutex_slot[mutex_index]);
		}

		if (this->_db == NULL) {
			// Handle closed by a failed reopen (ENOSPC path) — hard error,
			// never dereference NULL.
			throw -1;
		}

		string value;
		rocksdb::Status status = this->_db->Get(this->_read_options, e.key, &value);

		if (!status.ok()) {
			if (status.IsNotFound()) {
				log_debug("key not found (key=%s)", e.key.c_str());
				r = result_not_found;
			} else {
				log_err("RocksDB::Get() failed: %s", status.ToString().c_str());
				r = result_not_found;
			}
			throw 0;
		}

		if (value.size() < static_cast<size_t>(entry::header_size)) {
			log_err("invalid data size (key=%s, size=%zu)", e.key.c_str(), value.size());
			r = result_not_found;
			throw 0;
		}

		// Deserialize header
		const uint8_t* value_ptr = reinterpret_cast<const uint8_t*>(value.data());
		this->_unserialize_header(value_ptr, value.size(), e);

		// Check expiration
		if ((b & behavior_skip_timestamp) == 0 && e.expire > 0 && e.expire <= stats_object->get_timestamp()) {
			log_debug("entry expired (key=%s, expire=%ld, timestamp=%ld)",
				e.key.c_str(), e.expire, stats_object->get_timestamp());
			r = result_not_found;
			expired = true;
			throw 0;
		}

		// Copy data
		if (e.size > 0) {
			e.data = shared_byte(new uint8_t[e.size]);
			memcpy(e.data.get(), value_ptr + entry::header_size, e.size);
		}

		r = result_none;

	} catch (int error) {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
			pthread_rwlock_unlock(&this->_mutex_wholelock);
		}
		// Lazy expiry (mirrors storage_tch): physically remove the expired entry
		// so its space is reclaimed and — on the partition master — the delete
		// flows through the RocksDB WAL to replicas (a compaction filter would
		// bypass the WAL and diverge the followers). version_equal so a delete is
		// skipped if the key was re-set between the read and here. e already holds
		// the current header (version/expire) from _unserialize_header above.
		if (expired && !this->_lazy_expiry_delete) {
			// Not the partition master: the value is hidden (not_found
			// above) but stays on disk; the master's delete arrives through
			// the replication stream.
			this->_expire_filtered.incr();
		} else if (expired) {
			result r_remove;
			// behavior_skip_timestamp so remove() reports result_deleted rather
			// than result_not_found for the (known-expired) entry it deletes.
			if (this->remove(e, r_remove,
						(b & behavior_skip_lock) | behavior_skip_timestamp | behavior_version_equal) == 0
					&& r_remove == result_deleted) {
				this->_expire_reaped.incr();
			}
		}
		return error;
	}

	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		pthread_rwlock_unlock(&this->_mutex_wholelock);
	}

	return 0;
}

int storage_rocksdb::remove(entry& e, result& r, int b) {
	log_debug("remove (key=%s, behavior=%x)", e.key.c_str(), b);

	if (is_reserved_key(e.key)) {
		log_warning("refusing remove on reserved key (key=%s)", e.key.c_str());
		r = result_not_found;
		return 0;
	}

	int mutex_index = 0;
	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	try {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_rdlock(&this->_mutex_wholelock);
			pthread_rwlock_wrlock(&this->_mutex_slot[mutex_index]);
		}

		if (this->_db == NULL) {
			// Handle closed by a failed reopen (ENOSPC path) — hard error,
			// never dereference NULL.
			throw -1;
		}

		entry e_current;
		int e_current_exists = this->_get_header(e.key, e_current);
		if ((b & behavior_skip_version) == 0 && e.version != 0) {
			if (((b & behavior_version_equal) == 0 && e.version < e_current.version) || ((b & behavior_version_equal) != 0 && e.version != e_current.version)) {
				log_info("specified version is older than (or equal to) current version -> skip removing (current=%u, specified=%u)", e_current.version, e.version);
				r = result_not_found;
				throw 0;
			}
		}

		if (e_current_exists < 0) {
			log_debug("data not found in database -> skip removing and updating header cache if we need", 0);
			if (e.version != 0) {
				this->_set_header_cache(e.key, e);
			}
			r = result_not_found;
			throw 0;
		}

		bool expired = false;
		if ((b & behavior_skip_timestamp) == 0 && e_current.expire > 0 && e_current.expire <= stats_object->get_timestamp()) {
			log_info("data expired [expire=%d] -> result is NOT_FOUND but continue processing", e_current.expire);
			expired = true;
		}

		rocksdb::Status status = this->_db->Delete(this->_write_options, e.key);
		(void)this->_note_write_status(status, "remove");
		if (status.ok()) {
			r = expired ? result_not_found : result_deleted;
			// ORDER LABEL: same rule as set() — inside the slot lock.
			e.seq_label = this->_db->GetLatestSequenceNumber();
			// O(1) curr_items bookkeeping: the not-found path threw before this
			// point, so a physically present key was just deleted.
			this->_curr_items.decr();
			log_debug("removed data (key=%s)", e.key.c_str());
		} else {
			log_err("RocksDB::Delete() failed: %s", status.ToString().c_str());
			this->_listener->on_storage_error();
			throw -1;
		}

		if (e.version == 0) {
			e.version = e_current.version;
		}
		this->_set_header_cache(e.key, e);

	} catch (int e) {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
			pthread_rwlock_unlock(&this->_mutex_wholelock);
		}
		return e;
	}

	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		pthread_rwlock_unlock(&this->_mutex_wholelock);
	}

	return 0;
}

int storage_rocksdb::incr(entry& e, uint64_t value, result& r, bool increment, int b) {
	log_debug("incr (key=%s, value=%llu, increment=%d, behavior=%x)", e.key.c_str(), value, increment, b);

	if (is_reserved_key(e.key)) {
		log_warning("refusing incr on reserved key (key=%s)", e.key.c_str());
		r = result_not_found;
		return 0;
	}

	int mutex_index = 0;
	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	try {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_rdlock(&this->_mutex_wholelock);
			pthread_rwlock_wrlock(&this->_mutex_slot[mutex_index]);
		}

		if (this->_db == NULL) {
			// Handle closed by a failed reopen (ENOSPC path) — hard error,
			// never dereference NULL.
			throw -1;
		}

		// Get current entry
		entry e_current;
		e_current.key = e.key;
		int result_code = this->get(e_current, r, behavior_skip_lock | (b & behavior_skip_timestamp));

		if (result_code < 0 || r == result_not_found) {
			log_debug("key not found for incr/decr (key=%s)", e.key.c_str());
			r = result_not_found;
			throw 0;
		}

		// Parse current value as uint64 (matching storage_tcb behavior)
		// Truncate at first non-digit character
		uint64_t current_value = 0;
		if (e_current.size > 0 && e_current.data.get() != NULL) {
			uint8_t* q = e_current.data.get();
			size_t valid_len = 0;
			while (valid_len < e_current.size && *q) {
				if (isdigit(*q) == false) {
					break;
				}
				q++;
				valid_len++;
			}

			if (valid_len > 0) {
				string current_str(reinterpret_cast<char*>(e_current.data.get()), valid_len);
				try {
					current_value = boost::lexical_cast<uint64_t>(current_str);
				} catch (boost::bad_lexical_cast& e) {
					current_value = 0;
				}
			}
		}

		// Perform increment/decrement
		uint64_t new_value;
		if (increment) {
			new_value = current_value + value;
		} else {
			if (current_value < value) {
				new_value = 0;
			} else {
				new_value = current_value - value;
			}
		}

		// Convert back to string
		string new_value_str = boost::lexical_cast<string>(new_value);
		e.size = new_value_str.size();
		e.data = shared_byte(new uint8_t[e.size]);
		memcpy(e.data.get(), new_value_str.data(), e.size);
		e.flag = e_current.flag;
		e.expire = e_current.expire;
		e.version = e_current.version + 1;

		// Store updated value
		result set_result;
		int set_code = this->set(e, set_result, behavior_skip_lock);

		if (set_code < 0 || set_result != result_stored) {
			log_err("failed to store incr/decr result (key=%s)", e.key.c_str());
			r = result_not_stored;
			throw 0;
		}

r = result_stored;
		// ORDER LABEL: the nested set() captured it inside the slot lock we
		// are already holding (behavior_skip_lock), so it is this change's
		// label; incr/decr are forwarded as the RESULTING VALUE (design
		// §3.2), never re-computed on a replica.

	} catch (int e) {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
			pthread_rwlock_unlock(&this->_mutex_wholelock);
		}
		return e;
	}

	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		pthread_rwlock_unlock(&this->_mutex_wholelock);
	}

	return 0;
}

int storage_rocksdb::truncate(int b) {
	log_notice("truncating storage (this may take a while)", 0);
	// BULK OPERATION (design §3.9(B)): truncate / flush_all replace the
	// history rather than edit keys inside it, so no per-key order label is
	// meaningful and ordering a mass delete against in-flight forwarded
	// changes by label would be guesswork. Advance the SOURCE EPOCH instead:
	// followers refuse the old stream and rebuild. Done at the END of a
	// successful truncate (see below) so a failed truncate does not cost
	// every replica a rebuild.

	// Exclude every concurrent get/set/remove/incr (they hold the
	// wholelock in read mode plus a slot lock) while we scan-delete and
	// clear the header cache. Same locking convention as
	// storage_tcb::truncate().
	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_wrlock(&this->_mutex_wholelock);
		this->_mutex_slot_wrlock_all();
	}

	if (this->_db == NULL) {
		log_err("truncate: DB handle is closed (failed reopen) — refusing", 0);
		if ((b & behavior_skip_lock) == 0) {
			this->_mutex_slot_unlock_all();
			pthread_rwlock_unlock(&this->_mutex_wholelock);
		}
		return -1;
	}

	// Copy retention (design §2): the copy identity moves to its next
	// generation BEFORE anything is deleted, so a crash part-way never leaves
	// the old generation naming changed content (an approval for the old
	// generation must not apply to it). If it cannot be recorded, no truncate.
	if (this->bump_copy_generation("truncate (before deleting)") < 0) {
		log_err("truncate refused: the copy identity could not move to its next generation", 0);
		if ((b & behavior_skip_lock) == 0) {
			this->_mutex_slot_unlock_all();
			pthread_rwlock_unlock(&this->_mutex_wholelock);
		}
		return -1;
	}
	// TEST SEAM (unit tests only): stop right after the identity moved and
	// before anything is deleted — the state a crash at that point leaves
	{
		const char* seam = getenv("FLARE_TEST_TRUNCATE_STOP_AFTER_IDENTITY");
		if (seam != NULL && seam[0] != '\0' && strcmp(seam, "0") != 0) {
			log_warning("truncate stopped after the identity moved (FLARE_TEST_TRUNCATE_STOP_AFTER_IDENTITY test seam)", 0);
			if ((b & behavior_skip_lock) == 0) {
				this->_mutex_slot_unlock_all();
				pthread_rwlock_unlock(&this->_mutex_wholelock);
			}
			return -1;
		}
	}

	int r = 0;

	// Full table scan delete (RocksDB doesn't have fast truncate).
	// Reserved replication metadata keys are preserved: truncating them
	// would silently break WAL sync lineage tracking on the next sync.
	// If an operator truly wants to start over they can remove the DB
	// directory.
	rocksdb::Iterator* it = this->_db->NewIterator(this->_read_options);

	for (it->SeekToFirst(); it->Valid(); it->Next()) {
		string k = it->key().ToString();
		if (is_reserved_key(k)) {
			continue;
		}
		rocksdb::Status status = this->_db->Delete(this->_write_options, k);
		if (!this->_note_write_status(status, "truncate")) {
			log_err("RocksDB::Delete() failed during truncate: %s", status.ToString().c_str());
			r = -1;
			break;
		}
	}

	delete it;

	if (r == 0) {
		// Reset the replicated-LSN marker: after a truncate the slave is
		// logically empty from the application's perspective and the next
		// sync should start from scratch. The master-id lineage token is
		// preserved so that incremental sync with the current master can
		// continue if appropriate.
		rocksdb::WriteOptions wo;
		wo.sync = this->_sync_writes;
		wo.disableWAL = false;
		this->_db->Delete(wo, kReplLastLsnKey);
	}

	this->_clear_header_cache();

	// O(1) curr_items bookkeeping: all non-reserved keys are gone. Reset under
	// the wholelock (writes are excluded here, so a plain read-then-sub is
	// exact). On a partial failure (r != 0) leave the counter alone — it may
	// drift, but the storage error listener escalates anyway.
	if (r == 0) {
		this->_curr_items.sub(this->_curr_items.fetch());
	}

	// Advance the epoch BEFORE releasing the whole-lock, so no reader can
	// observe the truncated history still carrying the old epoch. Lock order
	// is whole-lock -> generations, the same as hard_reset().
	if (r == 0) {
		this->advance_source_epoch("bulk");
	}

	if ((b & behavior_skip_lock) == 0) {
		this->_mutex_slot_unlock_all();
		pthread_rwlock_unlock(&this->_mutex_wholelock);
	}

	if (r == 0) {
		log_notice("storage truncated (master_id preserved=%s, repl_last_lsn reset to 0)",
			this->get_master_id().c_str());
	}
	return r;
}

int storage_rocksdb::iter_begin() {
	log_debug("iter_begin()", 0);

	pthread_rwlock_rdlock(&this->_mutex_wholelock);

	if (this->_iter_snapshot) {
		log_warning("iteration already in progress", 0);
		// Release the wholelock acquired above: leaking a rdlock here
		// would permanently block any later wrlock (e.g. truncate()).
		pthread_rwlock_unlock(&this->_mutex_wholelock);
		return -1;
	}

	if (this->_db == NULL) {
		pthread_rwlock_unlock(&this->_mutex_wholelock);
		return -1;
	}

	// Create snapshot for consistent iteration
	this->_iter_snapshot = this->_db->GetSnapshot();

	// Localized read options for the iterator only — do not pollute
	// this->_read_options, which is used by Get() in set()/remove()/etc.
	rocksdb::ReadOptions iter_options = this->_read_options;
	iter_options.snapshot = this->_iter_snapshot;

	this->_iter = this->_db->NewIterator(iter_options);
	this->_iter->SeekToFirst();
	this->_iter_first = true;

	return 0;
}

storage::iteration storage_rocksdb::iter_next(string& key) {
	if (!this->_iter_snapshot || !this->_iter) {
		log_warning("iteration not initialized", 0);
		return iteration_error;
	}

	// Advance past any reserved replication metadata keys so iteration
	// (dump, reconstruction, orphan scan, etc.) never exposes them.
	for (;;) {
		if (this->_iter_first) {
			this->_iter_first = false;
		} else {
			this->_iter->Next();
		}

		if (!this->_iter->Valid()) {
			return iteration_end;
		}

		string candidate = this->_iter->key().ToString();
		if (is_reserved_key(candidate)) {
			continue;
		}
		key = candidate;
		return iteration_continue;
	}
}

namespace {
	// Defined later in this file, next to the named-backup code that also
	// uses it (anonymous namespaces in one TU merge, so this forward
	// declaration binds to that definition).
	int remove_tree(const string& path);

	// Recursive byte size of a directory tree (regular files; hardlinks are
	// counted once per name, an over-estimate, which is the safe side).
	uint64_t tree_bytes(const string& path) {
		DIR* d = opendir(path.c_str());
		if (d == NULL) {
			return 0;
		}
		uint64_t total = 0;
		struct dirent* ent;
		while ((ent = readdir(d)) != NULL) {
			string n = ent->d_name;
			if (n == "." || n == "..") {
				continue;
			}
			string child = path + "/" + n;
			struct stat st;
			if (lstat(child.c_str(), &st) != 0) {
				continue;
			}
			if (S_ISDIR(st.st_mode)) {
				total += tree_bytes(child);
			} else if (S_ISREG(st.st_mode)) {
				total += static_cast<uint64_t>(st.st_size);
			}
		}
		closedir(d);
		return total;
	}

	// First number in a one-line file, or -1 ("max" or unreadable).
	int64_t read_cgroup_number(const char* path) {
		FILE* fp = fopen(path, "r");
		if (fp == NULL) {
			return -1;
		}
		char buf[64] = {0};
		const char* got = fgets(buf, sizeof(buf), fp);
		fclose(fp);
		if (got == NULL || strncmp(buf, "max", 3) == 0) {
			return -1;
		}
		char* end = NULL;
		unsigned long long v = strtoull(buf, &end, 10);
		if (end == buf) {
			return -1;
		}
		return static_cast<int64_t>(v);
	}
}

uint64_t storage_rocksdb::local_copy_bytes() {
	return tree_bytes(this->_data_path);
}

int64_t storage_rocksdb::rebuild_space_available() {
	struct statvfs vfs;
	if (statvfs(this->_data_dir.c_str(), &vfs) != 0) {
		return -1;
	}
	int64_t avail = static_cast<int64_t>(static_cast<uint64_t>(vfs.f_bavail) * vfs.f_frsize);
	// tmpfs (TMPFS_MAGIC): the staged files are RAM charged to this
	// container's memory cgroup, so the binding limit is usually the cgroup,
	// not the tmpfs size (a pod whose tmpfs sizeLimit equals its memory limit
	// is OOM-killed long before the tmpfs is full).
	struct statfs fs;
	if (statfs(this->_data_dir.c_str(), &fs) == 0 && static_cast<unsigned long>(fs.f_type) == 0x01021994UL) {
		int64_t limit = read_cgroup_number("/sys/fs/cgroup/memory.max");
		int64_t used = read_cgroup_number("/sys/fs/cgroup/memory.current");
		if (limit < 0 || used < 0) {
			limit = read_cgroup_number("/sys/fs/cgroup/memory/memory.limit_in_bytes");
			used = read_cgroup_number("/sys/fs/cgroup/memory/memory.usage_in_bytes");
		}
		// cgroup v1 reports "no limit" as a huge number: treat as unlimited.
		if (limit > 0 && used >= 0 && limit < (static_cast<int64_t>(1) << 60)) {
			// no fixed margin: flared's own growth during the copy is part of
			// the configured reserve (rocksdb-rebuild-reserve-bytes, design §9)
			int64_t headroom = limit - used;
			if (headroom < 0) {
				headroom = 0;
			}
			if (headroom < avail) {
				avail = headroom;
			}
		}
	}
	return avail;
}

string storage_rocksdb::_restore_pending_path() const {
	return this->_data_dir + "/.flare_restore_pending";
}

/**
 *	A restore that did not finish must never be exposed (design §3.9(D)).
 *	Called from open() BEFORE the DB is opened: if the sentinel is present, the
 *	previous snapshot restore was interrupted and the directory holds the
 *	source's data with our replication metadata unset. Wipe it and come up
 *	empty; reconstruction reseeds. Returns true when it wiped.
 */
int storage_rocksdb::_discard_incomplete_restore() {
	const string pending = this->_restore_pending_path();
	struct stat sb;
	if (stat(pending.c_str(), &sb) != 0) {
		return 0;
	}
	log_err("an interrupted snapshot restore was found (sentinel=%s): the DB holds the source's data with our replication metadata unset -> discarding it and starting empty; reconstruction will reseed",
		pending.c_str());
	if (remove_tree(this->_data_path) != 0) {
		// FAIL CLOSED: opening the directory now would expose the source's
		// data under this node's identity with no cursor and no generations.
		// Refuse to open at all; the node stays down and is rebuilt.
		log_err("failed to remove the half-restored DB dir [%s] -> refusing to open it", this->_data_path.c_str());
		return -1;
	}
	if (unlink(pending.c_str()) != 0 && errno != ENOENT) {
		// The data is gone, so opening is safe, but leaving the sentinel
		// would discard the NEXT (good) restore as well.
		log_err("the half-restored DB was removed but its sentinel [%s] could not be: %s -> refusing to open (the next restore would be discarded too)",
			pending.c_str(), util::strerror(errno));
		return -1;
	}
	return 0;
}

int storage_rocksdb::create_snapshot_checkpoint(string& out_path, uint64_t& out_seq) {
	if (this->_db == NULL) {
		log_err("create_snapshot_checkpoint called before DB open", 0);
		return -1;
	}

	// COPY RETENTION (design §5): ONE serve at a time per source (a snapshot
	// to a replica or a push), each in its own directory
	// snapshot.serve.<request> — never a shared fixed path another transfer
	// could recreate under a running one. -2 = busy (the caller answers
	// "busy" and the requester waits). The slot is released by
	// remove_snapshot_checkpoint(), which every caller runs on every exit.
	pthread_mutex_lock(&this->_mutex_rebuild_status);
	if (this->_snapshot_serving) {
		pthread_mutex_unlock(&this->_mutex_rebuild_status);
		log_notice("snapshot serve refused: another snapshot is being served from this node (busy)", 0);
		return -2;
	}
	this->_snapshot_serving = true;
	pthread_mutex_unlock(&this->_mutex_rebuild_status);
	// Sibling of the DB dir, never under backups/ (the pruner cannot race
	// it); CreateCheckpoint creates the dir itself (it must not exist).
	const string path = this->_data_dir + "/snapshot.serve." + new_attempt_id();

	rocksdb::Checkpoint* cp = NULL;
	rocksdb::Status s = rocksdb::Checkpoint::Create(this->_db, &cp);
	if (!s.ok() || cp == NULL) {
		log_err("Checkpoint::Create failed: %s", s.ToString().c_str());
		this->_release_snapshot_serve();
		return -1;
	}

	// sequence_number_ptr: the exact sequence the checkpoint captures —
	// everything after it is in this node's WAL, so the receiver can finish
	// with an incremental WAL sync from out_seq. This is what makes the
	// physical reseed equivalent to (snapshot + binlog) bootstrap.
	uint64_t seq = 0;
	s = cp->CreateCheckpoint(path, 0 /* log_size_for_flush: default */, &seq);
	delete cp;
	if (!s.ok()) {
		log_err("CreateCheckpoint(%s) failed: %s", path.c_str(), s.ToString().c_str());
		remove_tree(path);
		this->_release_snapshot_serve();
		return -1;
	}

	out_path = path;
	out_seq = seq;
	log_notice("snapshot checkpoint created (path=%s, seq=%llu)", path.c_str(), (unsigned long long)seq);
	return 0;
}

int storage_rocksdb::disable_file_deletions() {
	pthread_rwlock_rdlock(&this->_mutex_wholelock);
	int r = -1;
	if (this->_db != NULL) {
		rocksdb::Status s = this->_db->DisableFileDeletions();
		if (s.ok()) {
			r = 0;
		} else {
			log_err("DisableFileDeletions failed: %s", s.ToString().c_str());
		}
	}
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return r;
}

int storage_rocksdb::enable_file_deletions() {
	pthread_rwlock_rdlock(&this->_mutex_wholelock);
	int r = -1;
	if (this->_db != NULL) {
		// non-forced: balances nested disable/enable pairs (each caller
		// releases only its own pin)
		rocksdb::Status s = this->_db->EnableFileDeletions(false);
		if (s.ok()) {
			r = 0;
		} else {
			log_err("EnableFileDeletions failed: %s", s.ToString().c_str());
		}
	}
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return r;
}

int storage_rocksdb::remove_snapshot_checkpoint(const string& path) {
	// Only ever remove a serve dir of our own — refuse anything else so a
	// bug in the caller cannot escalate into deleting the live DB.
	const string prefix = this->_data_dir + "/snapshot.serve.";
	if (path.size() <= prefix.size() || path.compare(0, prefix.size(), prefix) != 0
			|| path.find('/', prefix.size()) != string::npos) {
		log_err("refusing to remove non-staging path [%s]", path.c_str());
		return -1;
	}
	const int r = remove_tree(path);
	this->_release_snapshot_serve();
	return r;
}

void storage_rocksdb::_release_snapshot_serve() {
	pthread_mutex_lock(&this->_mutex_rebuild_status);
	this->_snapshot_serving = false;
	pthread_mutex_unlock(&this->_mutex_rebuild_status);
}

bool storage_rocksdb::is_snapshot_serving() {
	pthread_mutex_lock(&this->_mutex_rebuild_status);
	const bool b = this->_snapshot_serving;
	pthread_mutex_unlock(&this->_mutex_rebuild_status);
	return b;
}

int storage_rocksdb::remove_snapshot_staging(const string& path) {
	// Only ever remove our own receive staging dir.
	if (path != this->_data_dir + "/snapshot.recv.tmp") {
		log_err("refusing to remove non-staging path [%s]", path.c_str());
		return -1;
	}
	return remove_tree(path);
}

int storage_rocksdb::prepare_snapshot_staging(string& out_dir) {
	const string path = this->_data_dir + "/snapshot.recv.tmp";
	remove_tree(path);
	if (mkdir(path.c_str(), 0700) != 0) {
		log_err("failed to create snapshot staging dir [%s]: %s", path.c_str(), util::strerror(errno));
		return -1;
	}
	out_dir = path;
	return 0;
}

namespace {
	/**
	 *	Open a directory READ-ONLY with every column family it contains.
	 *	RocksDB refuses to open a directory whose families are not all listed,
	 *	and a checkpoint taken from a node that has applied deliveries carries
	 *	the replication-metadata family, so probes cannot use the one-argument
	 *	form any more.
	 */
	rocksdb::Status open_read_only_all_cfs(const rocksdb::Options& options,
			const string& dir, rocksdb::DB** db,
			vector<rocksdb::ColumnFamilyHandle*>& handles) {
		vector<string> names;
		rocksdb::Status ls = rocksdb::DB::ListColumnFamilies(rocksdb::DBOptions(options), dir, &names);
		if (!ls.ok() || names.empty()) {
			names.clear();
			names.push_back(rocksdb::kDefaultColumnFamilyName);
		}
		vector<rocksdb::ColumnFamilyDescriptor> descriptors;
		for (size_t i = 0; i < names.size(); i++) {
			descriptors.push_back(rocksdb::ColumnFamilyDescriptor(
				names[i], rocksdb::ColumnFamilyOptions(options)));
		}
		return rocksdb::DB::OpenForReadOnly(rocksdb::DBOptions(options), dir, descriptors, &handles, db);
	}

	void close_read_only(rocksdb::DB* db, vector<rocksdb::ColumnFamilyHandle*>& handles) {
		if (db == NULL) {
			return;
		}
		for (size_t i = 0; i < handles.size(); i++) {
			db->DestroyColumnFamilyHandle(handles[i]);
		}
		handles.clear();
		delete db;
	}
}

int storage_rocksdb::swap_in_snapshot(const string& staging_dir, uint64_t checkpoint_seq) {
	// STRUCTURAL VERIFICATION before the point of no return: open the staged
	// checkpoint read-only (parses MANIFEST + replays its WAL) and touch one
	// key. The per-file CRC in the transfer protocol catches transport
	// corruption; this catches everything else (truncated files, a bad
	// checkpoint). Refusing here keeps the CURRENT data intact and lets the
	// caller fall back to the logical dump — swapping first and discovering
	// corruption later leaves the node with a poisoned DB whose writes all
	// fail with a sticky Corruption status (observed live).
	{
		rocksdb::DB* probe = NULL;
		rocksdb::Options probe_options = this->_options;
		probe_options.create_if_missing = false;
		vector<rocksdb::ColumnFamilyHandle*> probe_handles;
		rocksdb::Status ps = open_read_only_all_cfs(probe_options, staging_dir, &probe, probe_handles);
		if (!ps.ok()) {
			log_err("swap_in_snapshot: staged checkpoint failed verification (open: %s) -> refusing swap", ps.ToString().c_str());
			return -1;
		}
		string tmp;
		rocksdb::Status gs = probe->Get(rocksdb::ReadOptions(), storage_rocksdb::kReplMasterIdKey, &tmp);
		// The SOURCE EPOCH check belongs HERE, before the point of no return.
		// It used to run after the rename: a checkpoint from a source that
		// predates epochs (pf-dev rc56 master -> rc64 replica, 2026-10-05) was
		// refused only once it had REPLACED the local DB, so the replica kept
		// the source's full copy, the fallback truncate (a key-by-key delete
		// on RocksDB) freed no space, the full dump wrote a second copy, and
		// the pod was OOM-killed on every retry.
		string epoch;
		rocksdb::Status es = probe->Get(rocksdb::ReadOptions(), storage_rocksdb::kReplSourceEpochKey, &epoch);
		close_read_only(probe, probe_handles);
		if (!gs.ok() && !gs.IsNotFound()) {
			log_err("swap_in_snapshot: staged checkpoint failed verification (read: %s) -> refusing swap", gs.ToString().c_str());
			return -1;
		}
		if (!es.ok() || epoch.empty()) {
			log_err("swap_in_snapshot: the staged checkpoint carries no source epoch (a source older than continuous replication?) -> refusing BEFORE the swap; the local DB is untouched and the caller falls back to the full dump", 0);
			return -1;
		}
	}

	// Exclusive access for the whole swap: writers/readers take the
	// wholelock in read mode, so a write lock parks every op while the DB
	// handle is torn down and rebuilt. The node is a Prepare slave during
	// reconstruction (balance 0, readiness-gated NotReady), so nothing
	// user-visible is interrupted.
	pthread_rwlock_wrlock(&this->_mutex_wholelock);

	int r = -1;
	do {
		if (this->_db != NULL) {
			// Flush is unnecessary (the DB is about to be discarded); just
			// close the handle (and its column family handles) so the
			// directory can be replaced.
			this->_close_db();
		}

		// INCOMPLETE-RESTORE SENTINEL (design §3.9(D)). Written as a sibling
		// of the DB directory — not inside it, so RocksDB never sees it —
		// BEFORE the old copy is destroyed, and removed only once the restore
		// batch has committed. A crash anywhere in between leaves it on disk,
		// and open() then refuses to expose the half-restored DB and wipes it
		// so reconstruction runs again. Reserved keys inherited from the
		// source cannot serve this purpose: the checkpoint carries the
		// SOURCE's copies of them.
		{
			const string pending = this->_restore_pending_path();
			FILE* fp = fopen(pending.c_str(), "w");
			if (fp == NULL) {
				log_err("swap_in_snapshot: could not create the restore sentinel [%s]: %s -> refusing the swap",
					pending.c_str(), util::strerror(errno));
				break;
			}
			fclose(fp);
		}

		if (remove_tree(this->_data_path) != 0) {
			log_err("swap_in_snapshot: failed to remove old DB dir [%s]", this->_data_path.c_str());
		}
		if (rename(staging_dir.c_str(), this->_data_path.c_str()) != 0) {
			log_err("swap_in_snapshot: rename(%s -> %s) failed: %s",
				staging_dir.c_str(), this->_data_path.c_str(), util::strerror(errno));
			// Try to come back up on an empty DB rather than staying closed:
			// reconstruction will retry with a full dump.
		}

		rocksdb::Status status = this->_open_db(this->_data_path);
		if (!status.ok()) {
			log_err("swap_in_snapshot: reopen failed: %s", status.ToString().c_str());
			this->_db = NULL;
			this->_emergency_reopen_empty("swap_in_snapshot");
			break;
		}

		// Lineage: the checkpoint carries the SOURCE's master-id reserved key;
		// adopt it as our in-memory token (mirrors what open() does).
		{
			string value;
			rocksdb::Status st = this->_db->Get(this->_read_options, kReplMasterIdKey, &value);
			if (st.ok()) {
				pthread_rwlock_wrlock(&this->_mutex_master_id);
				this->_master_id = value;
				pthread_rwlock_unlock(&this->_mutex_master_id);
			}
		}

		// Replication cursor := the checkpoint's exact sequence. Everything
		// after it is in the source's WAL; the follow-up incremental sync
		// starts here. (Write the marker with WAL enabled like set_repl_last_lsn.)
		{
			// ALL-OR-NOTHING RESTORE (design §3.9(D)). The checkpoint carries
			// the SOURCE's replication metadata — its cursor, its generations
			// and (once the metadata column family exists) its per-key labels
			// and tombstones. Those describe the source's relationship to ITS
			// source, not ours, so they are cleared here and replaced in ONE
			// batch that ends with a completion marker:
			//   - cursor := the checkpoint's exact sequence,
			//   - source epoch := the source's (we are now following that
			//     history),
			//   - incarnation := ours + 1 (our copy was replaced, so anything
			//     issued against the previous copy must be refused),
			//   - restore-done marker, written last IN THE SAME BATCH.
			// A crash before the batch commits leaves no marker, and an
			// unmarked DB is treated as an incomplete restore at open() and
			// rebuilt rather than exposed. Until this batch commits the node
			// accepts no delivery: it is inside the whole-lock and is a
			// Prepare slave with balance 0.
			rocksdb::WriteOptions wo;
			wo.sync = true;			// the marker must not outlive a crash unwritten
			wo.disableWAL = false;
			string lsn_value;
			try {
				lsn_value = boost::lexical_cast<string>(checkpoint_seq);
			} catch (...) {
				lsn_value = "0";
			}

			// The checkpoint carries the SOURCE's replication metadata — its
			// per-key labels and tombstones, expressed in ITS source's
			// sequence space (design §3.9(D)). Drop the whole family and
			// recreate it empty: an absent row is safe here because the
			// cursor is about to be set to the checkpoint sequence, and the
			// positional rule refuses everything at or below it.
			if (this->_cf_meta != NULL) {
				rocksdb::Status ds = this->_db->DropColumnFamily(this->_cf_meta);
				this->_db->DestroyColumnFamilyHandle(this->_cf_meta);
				this->_cf_meta = NULL;
				if (!ds.ok()) {
					log_err("swap_in_snapshot: could not drop the inherited replication metadata: %s -> refusing to complete the restore", ds.ToString().c_str());
					break;
				}
				rocksdb::ColumnFamilyHandle* fresh = NULL;
				rocksdb::Status cs = this->_db->CreateColumnFamily(
					rocksdb::ColumnFamilyOptions(this->_options), kReplMetaCfName, &fresh);
				if (!cs.ok()) {
					log_err("swap_in_snapshot: could not recreate the replication metadata family: %s", cs.ToString().c_str());
					break;
				}
				this->_cf_meta = fresh;
			}
			this->_tombstone_sweep_cursor.clear();

			// The SOURCE EPOCH is inherited from the checkpoint: we are now
			// following that history, and its identity is what our cursor
			// belongs to. A checkpoint without one is refused rather than
			// guessed — an unidentified history cannot be compared later.
			string inherited_epoch;
			{
				rocksdb::Status gs = this->_db->Get(this->_read_options, kReplSourceEpochKey, &inherited_epoch);
				if (!gs.ok() || inherited_epoch.empty()) {
					log_err("swap_in_snapshot: the checkpoint carries no source epoch -> refusing to complete the restore (the history could not be identified)", 0);
					break;
				}
			}
			// The RECEIVER INCARNATION is freshly minted, never derived from
			// what the checkpoint carries: a repeated restore must produce a
			// different identity every time, or a delivery issued against the
			// previous copy would be accepted onto this one.
			const string next_incarnation = _mint_generation(this->get_incarnation());

			rocksdb::WriteBatch restore;
			restore.Put(kReplLastLsnKey, lsn_value);
			restore.Put(kReplSourceEpochKey, inherited_epoch);
			restore.Put(kReplSourceEpochReasonKey, "inherited");
			restore.Put(kReplIncarnationKey, next_incarnation);
			restore.Put(kReplRestoreDoneKey, boost::lexical_cast<string>(checkpoint_seq));
			// The checkpoint carries the SOURCE's own rebuild evidence, which
			// says nothing about this copy: drop it (the inherited epoch
			// already identifies the history).
			restore.Delete(kReplRebuiltFromKey);
			rocksdb::Status st = this->_db->Write(wo, &restore);
			if (!st.ok()) {
				log_err("swap_in_snapshot: failed to complete the restore batch: %s", st.ToString().c_str());
				break;
			}
			pthread_rwlock_wrlock(&this->_mutex_generations);
			this->_source_epoch = inherited_epoch;
			this->_source_epoch_reason = "inherited";
			this->_incarnation = next_incarnation;
			this->_rebuilt_from_master_id.clear();
			this->_rebuilt_from_epoch.clear();
			this->_generations_broken = false;
			pthread_rwlock_unlock(&this->_mutex_generations);
			log_notice("restore completed (cursor=%llu, source_epoch=%s, incarnation=%s)",
				(unsigned long long)checkpoint_seq,
				inherited_epoch.c_str(), next_incarnation.c_str());
			// The restore is complete and durable: clear the sentinel. If it
			// cannot be removed the DB is GOOD but will be discarded and
			// rebuilt at the next start — costly, never unsafe. Say so at
			// error level so the cause is visible before that happens.
			{
				const string pending = this->_restore_pending_path();
				int attempts = 0;
				while (unlink(pending.c_str()) != 0 && errno != ENOENT && ++attempts < 3) {
					usleep(10000);
				}
				struct stat sb;
				if (stat(pending.c_str(), &sb) == 0) {
					log_err("swap_in_snapshot: the restore completed but its sentinel [%s] could not be removed: this node will DISCARD this copy and reconstruct again at the next start",
						pending.c_str());
				}
			}
		}

		// Reseed the O(1) curr_items counter with an EXACT scan. The estimate
		// property is unusable here: a checkpoint ships the unflushed tail as
		// WAL files, and estimate-num-keys does not see WAL-only keys — a
		// write-heavy source would seed a large undercount. The swap is a
		// rare one-time bootstrap, so a single fill_cache=false iteration is
		// the right trade (and it doubles as a read-through of the fresh DB).
		{
			uint64_t exact = 0;
			rocksdb::ReadOptions ro = this->_read_options;
			ro.fill_cache = false;
			rocksdb::Iterator* it = this->_db->NewIterator(ro);
			for (it->SeekToFirst(); it->Valid(); it->Next()) {
				if (!is_reserved_key(it->key().ToString())) {
					exact++;
				}
			}
			delete it;
			this->_curr_items.sub(this->_curr_items.fetch());
			if (exact > 0) this->_curr_items.add(exact);
		}

		this->_clear_header_cache();
		// The DB was replaced wholesale by a verified checkpoint, so a
		// corruption latch set against the OLD db (e.g. a corrupt incoming
		// batch during a preceding WAL-sync attempt) no longer describes
		// this storage. Leaving it set kept healthy reseeded slaves paging
		// rocksdb_corrupted=1 (observed live on wg-dev after the rc34 roll).
		this->_corrupted = false;
		this->incr_snapshot_bootstrap();
		// a different copy (the source's checkpoint carries the SOURCE's
		// identity key): mint this copy's own
		this->new_copy_identity("snapshot swap");
		log_notice("snapshot bootstrap complete (seq=%llu, master_id=%s)",
			(unsigned long long)checkpoint_seq, this->get_master_id().c_str());
		r = 0;
	} while (false);

	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return r;
}

int storage_rocksdb::analyze_checkpoint(const string& dir, FILE* out) {
#ifdef HAVE_LIBROCKSDB
	// Read-only open: no writes, no master-id minting, no counter seeding — the
	// checkpoint (typically an S3 backup copy) is left byte-identical. Reading
	// blob-indexed values does NOT require enable_blob_files; RocksDB
	// dereferences blob files transparently on read.
	rocksdb::DB* db = NULL;
	rocksdb::Options opt;
	opt.create_if_missing = false;
	vector<rocksdb::ColumnFamilyHandle*> cf_handles;
	rocksdb::Status s = open_read_only_all_cfs(opt, dir, &db, cf_handles);
	if (!s.ok()) {
		log_err("analyze_checkpoint: OpenForReadOnly(%s) failed: %s", dir.c_str(), s.ToString().c_str());
		return -1;
	}

	rocksdb::ReadOptions ro;
	ro.fill_cache = false;  // one-pass scan must not thrash the block cache
	rocksdb::Iterator* it = db->NewIterator(ro);
	if (it == NULL) {
		close_read_only(db, cf_handles);
		return -1;
	}

	time_t now = time(NULL);
	uint64_t count = 0, expired = 0, no_expire = 0, total_bytes = 0;
	fprintf(out, "key,expire,ttl,size\n");
	for (it->SeekToFirst(); it->Valid(); it->Next()) {
		const string k = it->key().ToString();
		if (is_reserved_key(k)) {
			continue;  // replication metadata keys are invisible to readers
		}
		rocksdb::Slice v = it->value();
		entry e;
		if (this->_unserialize_header(reinterpret_cast<const uint8_t*>(v.data()),
				static_cast<int>(v.size()), e) < 0) {
			continue;  // short/malformed value
		}
		long long ttl;
		if (e.expire == 0) {
			ttl = -1;  // no expiry
			no_expire++;
		} else {
			ttl = static_cast<long long>(e.expire) - static_cast<long long>(now);
			if (e.expire <= now) {
				expired++;  // logically expired but not yet reaped
			}
		}
		// Keys may legally contain commas, so quote. (Embedded double-quotes in
		// keys are vanishingly rare — not escaped; note it if it ever matters.)
		fprintf(out, "\"%s\",%lld,%lld,%llu\n",
			k.c_str(), static_cast<long long>(e.expire), ttl,
			static_cast<unsigned long long>(e.size));
		count++;
		total_bytes += e.size;
	}

	rocksdb::Status its = it->status();
	delete it;
	close_read_only(db, cf_handles);
	if (!its.ok()) {
		log_err("analyze_checkpoint: iteration error: %s", its.ToString().c_str());
		return -1;
	}
	fprintf(stderr,
		"analyze_checkpoint: keys=%llu expired_unreaped=%llu no_expire=%llu total_value_bytes=%llu\n",
		static_cast<unsigned long long>(count),
		static_cast<unsigned long long>(expired),
		static_cast<unsigned long long>(no_expire),
		static_cast<unsigned long long>(total_bytes));
	return 0;
#else
	(void)dir; (void)out;
	log_warning("analyze_checkpoint requested but RocksDB not compiled in", 0);
	return -1;
#endif
}

bool storage_rocksdb::_note_write_status(const rocksdb::Status& status, const char* where) {
	if (status.ok()) {
		return true;
	}
	if (status.IsCorruption()) {
		this->_corruption_detected.incr();
		if (!this->_corrupted) {
			// Log loudly ONCE per poison episode (a corrupt DB rejects every
			// subsequent write, so unguarded logging would flood).
			log_err("STORAGE CORRUPTION detected at %s: %s -> latching corrupted (a SLAVE self-heals via hard_reset on its next reconstruction; a MASTER needs operator attention)",
				where, status.ToString().c_str());
		}
		this->_corrupted = true;
	}
	return false;
}

int storage_rocksdb::verify_integrity() {
	pthread_rwlock_rdlock(&this->_mutex_wholelock);
	int r = 0;
	if (this->_db != NULL) {
		rocksdb::Status s = this->_db->VerifyChecksum();
		if (!s.ok()) {
			this->_corruption_detected.incr();
			if (!this->_corrupted) {
				log_err("STORAGE CORRUPTION found by periodic verify: %s -> latching corrupted", s.ToString().c_str());
			}
			this->_corrupted = true;
			r = -1;
		}
	}
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return r;
}

void storage_rocksdb::_prune_named_backups(int keep) {
	// Keep only the newest `keep` named backups under <data_dir>/backups/.
	// Names are timestamp-prefixed, so lexical order == chronological order
	// and the oldest sort first.
	const string backups_dir = this->_data_dir + "/backups";
	vector<string> names;
	DIR* d = opendir(backups_dir.c_str());
	if (d == NULL) {
		return;
	}
	struct dirent* ent;
	while ((ent = readdir(d)) != NULL) {
		string n = ent->d_name;
		if (n == "." || n == "..") {
			continue;
		}
		struct stat st;
		string child = backups_dir + "/" + n;
		if (lstat(child.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
			names.push_back(n);
		}
	}
	closedir(d);
	if (keep < 0) {
		keep = 0;
	}
	if (static_cast<int>(names.size()) <= keep) {
		return;
	}
	sort(names.begin(), names.end());
	int to_remove = static_cast<int>(names.size()) - keep;
	for (int i = 0; i < to_remove; i++) {
		string victim = backups_dir + "/" + names[i];
		if (remove_tree(victim) == 0) {
			log_notice("pruned old backup %s", victim.c_str());
		} else {
			log_warning("failed to fully prune old backup %s", victim.c_str());
		}
	}
}

int storage_rocksdb::_emergency_reopen_empty(const char* who) {
	// Last-ditch recovery for a failed reopen (typically ENOSPC on a full
	// data dir — observed live: hourly backup checkpoints hardlink-pinned
	// compacted-away SSTs until a tmpfs hit 100%, and the post-crash reopen
	// left _db NULL, turning every subsequent op into a SIGSEGV). Free
	// everything redundant we own — the unopenable DB dir and every local
	// backup checkpoint (tier-2 object storage holds the history; a local
	// checkpoint is worthless if flared cannot even open a DB) — and try
	// once more to come up EMPTY. Caller holds the wholelock in write mode
	// and _db is NULL. Returns 0 when serving again on an empty DB.
	remove_tree(this->_data_path);
	this->_prune_named_backups(0);
	rocksdb::Status status = this->_open_db(this->_data_path);
	if (!status.ok()) {
		log_err("%s: emergency empty reopen failed too (%s) — DB handle stays closed; ops fail cleanly and self-heal keeps retrying", who, status.ToString().c_str());
		this->_db = NULL;
		this->_corrupted = true;   // engage the slave self-heal retry loop
		return -1;
	}
	this->_curr_items.sub(this->_curr_items.fetch());
	this->_clear_header_cache();
	this->_corrupted = false;
	log_err("%s: reopen failed but recovered on an EMPTY DB (local backups pruned to free space); reconstruction must reseed", who);
	return 0;
}

int storage_rocksdb::hard_reset() {
	// In-process Case-A: discard the (corrupt) local DB entirely and reopen
	// empty. Same teardown/reopen as swap_in_snapshot, minus the staging
	// swap — reconstruction reseeds the data afterwards. The caller guarantees
	// this is not the last good copy (slave / reconstructing node only).
	pthread_rwlock_wrlock(&this->_mutex_wholelock);
	int r = -1;
	do {
		if (this->_db != NULL) {
			this->_close_db();
		}
		if (remove_tree(this->_data_path) != 0) {
			log_err("hard_reset: failed to remove data dir [%s] -> reopen may still fail", this->_data_path.c_str());
		}
		rocksdb::Status status = this->_open_db(this->_data_path);
		if (!status.ok()) {
			log_err("hard_reset: reopen failed: %s", status.ToString().c_str());
			this->_db = NULL;
			if (this->_emergency_reopen_empty("hard_reset") != 0) {
				break;
			}
		}
		// Empty DB: reset the live-key counter and clear the corruption latch.
		this->_curr_items.sub(this->_curr_items.fetch());
		this->_clear_header_cache();
		this->_corrupted = false;
		this->_hard_reset.incr();
		this->new_copy_identity("reset to an empty copy");
		// The local copy was replaced: deliveries and streams issued against
		// the previous copy must be refused (design §3.1). hard_reset reopens
		// the handle directly, so establish the generations here. The DB is
		// empty, so _load_or_init_generations() MINTS both — a fresh identity
		// per reset, which is what makes a repeated hard reset distinguishable
		// (a counter would return to the same value every time). Its history
		// is gone too, so the source epoch is new as well.
		if (this->_load_or_init_generations() < 0) {
			log_err("hard_reset: could not establish replication generations; replication stays UNAVAILABLE on this node", 0);
		}
		// A fresh empty DB has no lineage; repl_last_lsn is 0, so the next
		// reconstruction takes the clean full/snapshot reseed path.
		log_notice("hard_reset: wiped and reopened empty DB [%s]; reconstruction will reseed", this->_data_path.c_str());
		r = 0;
	} while (false);
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return r;
}

int storage_rocksdb::quarantine_reset(string& moved_to) {
	moved_to.clear();
	// design §6: ONE generation. Another quarantine already here: stop and
	// notify; nothing is moved or deleted (its removal needs an approval).
	{
		DIR* d = opendir(this->_data_dir.c_str());
		if (d != NULL) {
			struct dirent* e;
			string found;
			while ((e = readdir(d)) != NULL) {
				const string n = e->d_name;
				if (n.compare(0, 11, "quarantine-") == 0) {
					found = n;
					break;
				}
			}
			closedir(d);
			if (!found.empty()) {
				this->set_rebuild_blocked("quarantine_full");
				log_err("CRITICAL: rebuild_blocked=quarantine_full — a quarantined copy [%s] is already kept (one generation); the corrupt copy is NOT moved and NOTHING is deleted (operator action / approval needed)", found.c_str());
				return -1;
			}
		}
	}
	pthread_rwlock_wrlock(&this->_mutex_wholelock);
	int r = -1;
	do {
		string cid = this->get_copy_id();
		if (cid.empty()) {
			ostringstream u;
			u << "unknown-" << time(NULL) << "-" << getpid();
			cid = u.str();
		}
		// 1. the marker FIRST, durable: from here on, whatever is live after a
		//    crash is treated as the post-quarantine copy (not a healthy one)
		if (copy_fs::write_file_durable(this->_data_dir, kQuarantineMarkerFile, "corrupt=" + cid + "\n") < 0) {
			log_err("quarantine_reset: could not write the quarantine marker -> NOTHING moved", 0);
			break;
		}
		moved_to = this->_data_dir + "/quarantine-" + cid;
		if (this->_db != NULL) {
			this->_close_db();
		}
		// 2. the corrupt copy moves aside (never deleted)
		if (copy_fs::rename_durable(this->_data_dir, this->_data_path, moved_to) < 0) {
			const int e = errno;
			log_err("quarantine_reset: could not move the corrupt DB [%s] aside to [%s]: %s -> NOTHING deleted; reopening it as it is",
				this->_data_path.c_str(), moved_to.c_str(), strerror(e));
			rocksdb::Status reopen = this->_open_db(this->_data_path);
			if (!reopen.ok()) {
				log_err("quarantine_reset: reopening the corrupt DB failed too: %s (the node stays unusable; operator action needed)", reopen.ToString().c_str());
				this->_db = NULL;
			}
			moved_to.clear();
			break;
		}
		// 3. a new empty copy
		rocksdb::Status status = this->_open_db(this->_data_path);
		if (!status.ok()) {
			log_err("quarantine_reset: reopen of an empty DB failed: %s", status.ToString().c_str());
			this->_db = NULL;
			if (this->_emergency_reopen_empty("quarantine_reset") != 0) {
				break;
			}
		}
		this->_curr_items.sub(this->_curr_items.fetch());
		this->_clear_header_cache();
		this->_corrupted = false;
		this->_hard_reset.incr();
		this->new_copy_identity("reset to an empty copy after quarantine");
		if (this->_load_or_init_generations() < 0) {
			log_err("quarantine_reset: could not establish replication generations; replication stays UNAVAILABLE on this node", 0);
		}
		// the marker names the empty copy too: it stays "post-quarantine"
		// until a verified rebuild replaces it
		copy_fs::write_file_durable(this->_data_dir, kQuarantineMarkerFile, "corrupt=" + cid + "\nempty=" + this->get_copy_id() + "\n");
		this->_quarantined = true;
		log_warning("quarantine_reset: the corrupt DB was MOVED ASIDE to [%s] (kept, not deleted) and an empty copy %s opened; it is NOT a healthy copy (stats rocksdb_quarantined=1: no reads, not promotable, not a repair source) until a verified rebuild replaces it",
			moved_to.c_str(), this->get_copy_id().c_str());
		r = 0;
	} while (false);
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return r;
}

namespace {
	// lines "<request id> <state>" of the approvals record; the LAST state wins
	string approval_state(const string& text, const string& request_id) {
		string state;
		string::size_type at = 0;
		while (at < text.size()) {
			string::size_type nl = text.find('\n', at);
			const string line = text.substr(at, nl == string::npos ? string::npos : nl - at);
			at = nl == string::npos ? text.size() : nl + 1;
			const string::size_type sp = line.find(' ');
			if (sp != string::npos && line.compare(0, sp, request_id) == 0 && sp == request_id.size()) {
				state = line.substr(sp + 1);
			}
		}
		return state;
	}

	int append_durable(const string& path, const string& line) {
		FILE* f = fopen(path.c_str(), "a");
		if (f == NULL) return -1;
		const bool ok = fputs(line.c_str(), f) >= 0 && fflush(f) == 0 && fsync(fileno(f)) == 0;
		fclose(f);
		return ok ? 0 : -1;
	}
}

int storage_rocksdb::discard_copy(const string& request_id, const string& operation, const string& copy_id,
		bool may_discard_live, string& result) {
	result.clear();
	if (request_id.empty() || request_id.size() > 128 || request_id.find_first_of(" \t\r\n") != string::npos
			|| copy_id.empty() || copy_id.find_first_of(" \t\r\n/") != string::npos) {
		result = "refused:malformed";
		return 0;
	}
	if (operation != "discard-retained" && operation != "discard-quarantine" && operation != "discard-before-copy") {
		result = "refused:unknown_operation";
		return 0;
	}
	const string ledger = this->_data_dir + "/" + kApprovalsFile;
	string text;
	copy_fs::read_small_file(ledger, text);
	{
		const string prev = approval_state(text, request_id);
		if (!prev.empty()) {
			result = "already:" + prev;		// one-shot: never executed twice
			return 0;
		}
	}
	// what is named must be exactly what is here, and a healthy copy
	string target;
	if (operation == "discard-retained") {
		const vector<string> rs = this->list_retained();
		for (size_t i = 0; i < rs.size(); i++) {
			const string dir = this->_data_dir + "/" + copy_fs::kRetainedPrefix + rs[i];
			if (copy_fs::read_copy_id(dir) == copy_id) target = dir;
		}
	} else if (operation == "discard-quarantine") {
		const string dir = this->_data_dir + "/quarantine-" + copy_id;
		if (copy_fs::dir_exists(dir)) target = dir;
	} else {
		if (!may_discard_live) {
			result = "refused:live_copy_of_a_master_or_serving_node";
		} else if (!this->copy_identity_consistent()) {
			result = "refused:identity_inconsistent";
		} else if (this->get_copy_id() != copy_id) {
			result = "refused:copy_changed";
		} else {
			target = this->_data_path;
		}
		if (!result.empty()) {
			append_durable(ledger, request_id + " " + result + "\n");
			return 0;
		}
	}
	if (target.empty()) {
		result = "refused:no_such_copy";
		append_durable(ledger, request_id + " " + result + "\n");
		return 0;
	}
	// recorded BEFORE anything is deleted
	if (append_durable(ledger, request_id + " started\n") < 0) {
		result = "refused:approval_record_unwritable";
		return 0;
	}
	int r = -1;
	if (operation == "discard-before-copy") {
		r = this->hard_reset();
	} else {
		r = copy_fs::remove_tree_path(target);
		copy_fs::fsync_dir(this->_data_dir);
		if (r == 0 && operation == "discard-quarantine" && this->get_rebuild_blocked() == "quarantine_full") {
			this->set_rebuild_blocked("");
		}
	}
	result = r == 0 ? "applied" : "failed";
	append_durable(ledger, request_id + " " + result + "\n");
	log_warning("APPROVED copy discard %s: %s of copy %s (%s) -> %s", request_id.c_str(), operation.c_str(), copy_id.c_str(), target.c_str(), result.c_str());
	return 0;
}

bool storage_rocksdb::_quarantined_now() {
	string text;
	if (copy_fs::read_small_file(this->_data_dir + "/" + kQuarantineMarkerFile, text) < 0) {
		return false;
	}
	const string::size_type e = text.find("empty=");
	if (e == string::npos) {
		return true;		// a crash before the empty copy was recorded: whatever is live is that copy
	}
	string empty_id = text.substr(e + 6);
	const string::size_type nl = empty_id.find('\n');
	if (nl != string::npos) empty_id.erase(nl);
	return empty_id.empty() || empty_id == this->get_copy_id();
}

int storage_rocksdb::_clear_quarantine_marker(const char* why) {
	const string p = this->_data_dir + "/" + kQuarantineMarkerFile;
	if (unlink(p.c_str()) != 0 && errno != ENOENT) {
		log_err("could not remove the quarantine marker [%s]: %s", p.c_str(), strerror(errno));
		return -1;
	}
	copy_fs::fsync_dir(this->_data_dir);
	this->_quarantined = false;
	log_notice("quarantine marker removed: %s (the quarantined copy itself is kept)", why);
	return 0;
}

int storage_rocksdb::reap_expired(time_t now, uint32_t max_scan, const string& after_key,
		string& last_key, bool& more, uint32_t& scanned, uint32_t& reaped,
		vector<entry>* reaped_entries) {
	scanned = 0;
	reaped = 0;
	more = false;
	last_key = after_key;

	// Best-effort sweep over the live DB. We deliberately do NOT take a
	// long-lived snapshot (unlike iter_begin) so the caller can throttle a
	// full-keyspace scan across many chunks without pinning superversions and
	// blocking compaction from reclaiming space between chunks. A fresh
	// iterator per chunk sees a slightly newer view each time, which is fine:
	// reaping is idempotent and re-scanning a key is cheap.
	if (this->_db == NULL) {
		return -1;
	}
	rocksdb::ReadOptions ro = this->_read_options;
	ro.fill_cache = false;                 // a full sweep must not thrash the block cache
	rocksdb::Iterator* it = this->_db->NewIterator(ro);
	if (it == NULL) {
		log_err("reap_expired: NewIterator returned NULL", 0);
		return -1;
	}

	if (after_key.empty()) {
		it->SeekToFirst();
	} else {
		// Resume strictly after the previous chunk's last key.
		it->Seek(after_key);
		if (it->Valid() && it->key().ToString() == after_key) {
			it->Next();
		}
	}

	while (it->Valid()) {
		if (scanned >= max_scan) {
			more = true;                   // stopped on the budget, not end-of-keyspace
			break;
		}
		string key = it->key().ToString();
		last_key = key;
		scanned++;

		if (is_reserved_key(key)) {
			it->Next();
			continue;
		}

		rocksdb::Slice value = it->value();
		if (value.size() >= static_cast<size_t>(entry::header_size)) {
			entry hdr;
			const uint8_t* value_ptr = reinterpret_cast<const uint8_t*>(value.data());
			this->_unserialize_header(value_ptr, value.size(), hdr);
			if (hdr.expire > 0 && hdr.expire <= now) {
				// Delete only if the version is unchanged since we read the header
				// (a concurrent set may have refreshed / un-expired the key).
				// remove() is a LOCAL storage write (it lands in this node's WAL,
				// which live slaves do NOT consume — WAL sync is reconstruction-
				// only); replication is the caller's job via reaped_entries.
				// remove() takes its own per-slot lock.
				entry del;
				del.key = key;
				del.version = hdr.version;
				result r;
				// behavior_skip_timestamp: we already know it is expired and want
				// the delete to REPORT result_deleted. Without it, remove() treats
				// an expired entry as already-gone and returns result_not_found
				// (even though it deletes), which would under-count the reap.
				if (this->remove(del, r, behavior_skip_timestamp | behavior_version_equal) == 0
						&& r == result_deleted) {
					reaped++;
					this->_expire_reaped.incr();
					if (reaped_entries != NULL) {
						reaped_entries->push_back(del);   // key + the version we deleted at
					}
				}
			}
		}

		it->Next();
	}

	delete it;
	return 0;
}

int storage_rocksdb::iter_end() {
	log_debug("iter_end()", 0);

	if (!this->_iter && !this->_iter_snapshot) {
		log_warning("cursor is not initialized", 0);
		return -1;
	}

	if (this->_iter) {
		delete this->_iter;
		this->_iter = NULL;
	}

	if (this->_iter_snapshot) {
		this->_db->ReleaseSnapshot(this->_iter_snapshot);
		this->_iter_snapshot = NULL;
	}

	pthread_rwlock_unlock(&this->_mutex_wholelock);

	return 0;
}

uint32_t storage_rocksdb::count() {
	// O(1): incrementally-maintained live-key counter (see _curr_items in the
	// header). The previous implementation iterated the ENTIRE keyspace per
	// call — and `stats` calls this, and the exporter polls `stats`
	// periodically, so every scrape burned a full O(N) sweep and thrashed the
	// block cache.
	return static_cast<uint32_t>(this->_curr_items.fetch());
}

uint64_t storage_rocksdb::size() {
	uint64_t size = 0;
	std::string value;

	if (this->_db == NULL) {
		return 0;
	}

	// Get approximate size from RocksDB property
	if (this->_db->GetProperty("rocksdb.total-sst-files-size", &value)) {
		size = boost::lexical_cast<uint64_t>(value);
	}

	return size;
}

bool storage_rocksdb::is_capable(capability c) {
	// RocksDB doesn't support prefix search or list operations natively
	return false;
}

// WAL replication methods
uint64_t storage_rocksdb::get_latest_sequence_number() {
	// D6: callers are outside storage's own locks (stats, features, the WAL
	// server, promotion); a DB handle swap (snapshot swap, hard_reset,
	// truncate) holds the whole-lock for write, so read it under the
	// whole-lock to never touch a handle being replaced. Internal callers
	// (set/remove) read _db directly under their own locks.
	pthread_rwlock_rdlock(&this->_mutex_wholelock);
	uint64_t v = (this->_db == NULL) ? 0 : this->_db->GetLatestSequenceNumber();
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return v;
}

int storage_rocksdb::get_updates_since(uint64_t seq_number, vector<pair<uint64_t, rocksdb::WriteBatch>>& updates,
		uint64_t max_batches, uint64_t max_bytes, bool* more) {
	if (more != NULL) {
		*more = false;
	}
	// D6: hold the whole-lock for READ while the iterator lives, so a DB
	// handle swap (snapshot swap, hard_reset, truncate: whole-lock WRITE)
	// can never free the handle under it. Writers also take it for read,
	// so serving a follower does not block writes; the read is bounded by
	// max_batches/max_bytes. The lock is released on every return path
	// (the RAII guard), after the iterator is destroyed.
	struct wholelock_reader {
		pthread_rwlock_t* l;
		explicit wholelock_reader(pthread_rwlock_t* x) : l(x) { pthread_rwlock_rdlock(l); }
		~wholelock_reader() { pthread_rwlock_unlock(l); }
	} guard(&this->_mutex_wholelock);
	if (this->_db == NULL) {
		return -1;
	}
	// Use RocksDB's GetUpdatesSince for WAL-based replication
	std::unique_ptr<rocksdb::TransactionLogIterator> iter;
	rocksdb::Status status = this->_db->GetUpdatesSince(seq_number, &iter);

	if (!status.ok()) {
		if (status.IsNotFound()) {
			log_warning("LSN %llu not found (purged from WAL)", seq_number);
			return ERR_LSN_PURGED;
		}
		log_err("GetUpdatesSince failed: %s", status.ToString().c_str());
		return ERR_LSN_INVALID;
	}

	uint64_t bytes = 0;
	while (iter->Valid()) {
		if ((max_batches > 0 && updates.size() >= max_batches)
				|| (max_bytes > 0 && bytes >= max_bytes)) {
			// Stop READING, not just sending: the point of the bound is that
			// a far-behind reader cannot make us materialise its whole
			// backlog.
			if (more != NULL) {
				*more = true;
			}
			break;
		}
		rocksdb::BatchResult batch = iter->GetBatch();
		bytes += batch.writeBatchPtr->Data().size();
		// Copy the WriteBatch contents since writeBatchPtr is a unique_ptr
		updates.push_back(std::make_pair(batch.sequence, *batch.writeBatchPtr));
		iter->Next();
	}

	return 0;
}

namespace {
// Computes the live-key delta a WriteBatch will cause, BEFORE it is applied:
// +1 for a Put creating a key, -1 for a Delete of an existing key, 0 for
// overwrites / deletes of absent keys / reserved replication-metadata keys.
// Same-key sequences inside one batch are simulated via the overlay so e.g.
// Put+Delete of a fresh key nets 0. Existence probes are memtable/bloom-cheap
// (replicated keys were just written on the master moments ago).
class curr_items_delta_handler : public rocksdb::WriteBatch::Handler {
public:
	rocksdb::DB* db;
	const rocksdb::ReadOptions* ro;
	std::map<std::string, bool> overlay;
	int64_t delta;

	curr_items_delta_handler(rocksdb::DB* db_, const rocksdb::ReadOptions* ro_):
			db(db_), ro(ro_), delta(0) {}

	rocksdb::Status PutCF(uint32_t, const rocksdb::Slice& key, const rocksdb::Slice&) override {
		this->_track(key.ToString(), true);
		return rocksdb::Status::OK();
	}
	rocksdb::Status DeleteCF(uint32_t, const rocksdb::Slice& key) override {
		this->_track(key.ToString(), false);
		return rocksdb::Status::OK();
	}
	rocksdb::Status SingleDeleteCF(uint32_t, const rocksdb::Slice& key) override {
		this->_track(key.ToString(), false);
		return rocksdb::Status::OK();
	}

private:
	void _track(const std::string& k, bool present_after) {
		if (storage_rocksdb::is_reserved_key(k)) {
			return;
		}
		bool present_before;
		std::map<std::string, bool>::iterator it = this->overlay.find(k);
		if (it != this->overlay.end()) {
			present_before = it->second;
		} else {
			std::string v;
			present_before = this->db->Get(*this->ro, k, &v).ok();
		}
		if (!present_before && present_after) {
			this->delta++;
		} else if (present_before && !present_after) {
			this->delta--;
		}
		this->overlay[k] = present_after;
	}
};
}	// anonymous namespace

int storage_rocksdb::apply_batch(const rocksdb::WriteBatch& batch) {
	if (this->_db == NULL) {
		return -1;
	}
	// O(1) curr_items bookkeeping for the replica path: replicated batches
	// bypass set()/remove(), so walk the batch for its live-key delta first.
	curr_items_delta_handler h(this->_db, &this->_read_options);
	const_cast<rocksdb::WriteBatch&>(batch).Iterate(&h);
	// WriteBatch is passed as const reference, but Write() needs non-const pointer
	rocksdb::WriteBatch* batch_ptr = const_cast<rocksdb::WriteBatch*>(&batch);
	rocksdb::Status status = this->_db->Write(this->_write_options, batch_ptr);
	if (!status.ok()) {
		log_err("WriteBatch apply failed: %s", status.ToString().c_str());
		return -1;
	}
	if (h.delta > 0) {
		this->_curr_items.add(static_cast<uint64_t>(h.delta));
	} else if (h.delta < 0) {
		this->_curr_items.sub(static_cast<uint64_t>(-h.delta));
	}
	return 0;
}

bool storage_rocksdb::validate_batch_rep(const rocksdb::WriteBatch& batch) {
	// Structural walk of the serialized rep WITHOUT applying anything.
	// Senders call this before putting a batch on the wire: a batch that is
	// already corrupt at read time (e.g. a torn read of the live WAL) would
	// otherwise CRC-match in transit and poison the receiver at Write().
	struct noop_handler : public rocksdb::WriteBatch::Handler {
		rocksdb::Status PutCF(uint32_t, const rocksdb::Slice&, const rocksdb::Slice&) { return rocksdb::Status::OK(); }
		rocksdb::Status DeleteCF(uint32_t, const rocksdb::Slice&) { return rocksdb::Status::OK(); }
		rocksdb::Status SingleDeleteCF(uint32_t, const rocksdb::Slice&) { return rocksdb::Status::OK(); }
		rocksdb::Status MergeCF(uint32_t, const rocksdb::Slice&, const rocksdb::Slice&) { return rocksdb::Status::OK(); }
		rocksdb::Status DeleteRangeCF(uint32_t, const rocksdb::Slice&, const rocksdb::Slice&) { return rocksdb::Status::OK(); }
		void LogData(const rocksdb::Slice&) {}
	} h;
	return batch.Iterate(&h).ok();
}

// ===========================================================================
// COMMON APPLY RULE (SAF-10b, design §3.3 / §3.4 / §3.5 / §3.8)
//
// Both delivery paths reach storage through this section. Nothing here
// applies a raw WriteBatch: the WAL stream is DECODED into changes first, so
// a forwarded change and its WAL copy are compared by the same rule instead
// of one silently overwriting the other.
// ===========================================================================

int storage_rocksdb::_read_repl_meta(const string& key, repl_meta& out) {
	if (this->_db == NULL || this->_cf_meta == NULL) {
		return -1;
	}
	string value;
	rocksdb::Status st = this->_db->Get(this->_read_options, this->_cf_meta, key, &value);
	if (st.IsNotFound()) {
		return 1;
	}
	if (!st.ok()) {
		log_err("failed to read replication metadata for [%s]: %s", key.c_str(), st.ToString().c_str());
		return -1;
	}
	// "<epoch>|<label>|<deleted>" — the epoch is "<n>:<uuid>" and carries no
	// separator, so two splits from the right are unambiguous.
	string::size_type p2 = value.rfind('|');
	if (p2 == string::npos || p2 == 0) {
		log_err("malformed replication metadata for [%s]", key.c_str());
		return -1;
	}
	string::size_type p1 = value.rfind('|', p2 - 1);
	if (p1 == string::npos) {
		log_err("malformed replication metadata for [%s]", key.c_str());
		return -1;
	}
	try {
		out.epoch = value.substr(0, p1);
		out.label = boost::lexical_cast<uint64_t>(value.substr(p1 + 1, p2 - p1 - 1));
		out.deleted = (value.substr(p2 + 1) == "1");
	} catch (boost::bad_lexical_cast&) {
		log_err("unparseable replication metadata for [%s]", key.c_str());
		return -1;
	}
	return 0;
}

void storage_rocksdb::_stage_repl_meta(rocksdb::WriteBatch& batch, const string& key,
		const string& epoch, uint64_t label, bool deleted) {
	string value = epoch + "|" + boost::lexical_cast<string>(label) + "|" + (deleted ? "1" : "0");
	batch.Put(this->_cf_meta, key, value);
}

/**
 *	The rule, with no I/O so it can be reasoned about and tested directly.
 *
 *	Order of the tests matters:
 *	  1. the change must belong to the history this node is following;
 *	  2. a change at or below the applied position has already been fetched
 *	     from the WAL and decided — re-deciding it could only undo a later
 *	     decision, and this is what lets a tombstone be dropped once the
 *	     position passes the delete (§3.5);
 *	  3. otherwise compare against what this key already carries.
 *	Metadata that belongs to another epoch is treated as ABSENT rather than
 *	compared: labels from two histories are not comparable.
 */
storage_rocksdb::apply_outcome storage_rocksdb::_decide_change(const string& epoch,
		uint64_t label, bool have_meta, const repl_meta& current, uint64_t applied_cursor) {
	if (epoch.empty()) {
		return apply_refused_session;
	}
	const string local_epoch = this->get_source_epoch();
	if (local_epoch.empty() || local_epoch != epoch) {
		return apply_refused_session;
	}
	if (label <= applied_cursor) {
		return apply_refused_cursor;
	}
	if (have_meta && current.epoch == epoch && label <= current.label) {
		return apply_skipped_superseded;
	}
	return apply_applied;
}

/**
 *	Entry point for a forwarded change that arrived with an identity on the
 *	wire ("<epoch>/<label>"). Everything the rule needs travels with the
 *	change except the receiver incarnation, which the source cannot know: the
 *	protection against a delivery for a previous copy therefore rests on the
 *	epoch and on the applied position, both of which a restore resets (design
 *	§3.5), not on the incarnation for this path.
 */
int storage_rocksdb::apply_identified_change(const string& tag, entry& e, bool is_delete) {
	const string::size_type slash = tag.rfind('/');
	if (slash == string::npos || slash == 0 || slash + 1 >= tag.size()) {
		log_warning("malformed replication tag [%s] on a forwarded change (key=%s)", tag.c_str(), e.key.c_str());
		return identified_refused;
	}
	const string epoch = tag.substr(0, slash);
	uint64_t label = 0;
	try {
		label = boost::lexical_cast<uint64_t>(tag.substr(slash + 1));
	} catch (boost::bad_lexical_cast&) {
		log_warning("unparseable label in replication tag [%s] (key=%s)", tag.c_str(), e.key.c_str());
		return identified_refused;
	}
	if (label == 0) {
		return identified_refused;
	}

	const apply_outcome outcome = this->apply_forwarded_change(epoch, "", label, e, is_delete);
	switch (outcome) {
		case apply_applied:
			return identified_applied;
		case apply_skipped_superseded:
		case apply_refused_cursor:
			// Not an error: this copy already holds this change or a newer
			// one, so the source is not ahead of us and must not count a
			// drop — that would request a repair for nothing.
			return identified_skipped;
		case apply_refused_session:
		case apply_refused_incarnation:
			// We are not following this history. The source must hear about
			// it: its retry and drop accounting are what surface the
			// divergence to the controller.
			return identified_refused;
		default:
			return identified_error;
	}
}

/**
 *	Forwarded delivery of one change (design §3.8: SHARED apply lock + the
 *	key's slot lock; the applied position is read inside that section, never
 *	carried over from before a queue wait or a retry).
 */
storage_rocksdb::apply_outcome storage_rocksdb::apply_forwarded_change(const string& source_epoch,
		const string& incarnation, uint64_t label, entry& e, bool is_delete) {
	if (is_reserved_key(e.key)) {
		return apply_refused_session;
	}
	const uint64_t fw0 = repl_now_us();
	pthread_rwlock_rdlock(&this->_repl_apply_lock);
	repl_atomic_max(&this->_repl_forward_lock_wait_us_max, repl_now_us() - fw0);
	pthread_rwlock_rdlock(&this->_mutex_wholelock);
	const int mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	pthread_rwlock_wrlock(&this->_mutex_slot[mutex_index]);

	apply_outcome outcome = apply_error;
	do {
		// The DB handle is only valid while the whole-lock is held: a
		// snapshot swap, a hard reset or a close takes it in write mode and
		// destroys the handle. Check it here, never before.
		if (this->_db == NULL || this->_cf_meta == NULL) {
			break;
		}
		// A delivery issued against a copy this node no longer is must not
		// land on the new one (design §3.1). Read INSIDE the section for the
		// same reason the position is: the copy may have been replaced while
		// this change waited for a connection, a retry or a lock.
		const string local_incarnation = this->get_incarnation();
		if (local_incarnation.empty() || (!incarnation.empty() && incarnation != local_incarnation)) {
			outcome = apply_refused_incarnation;
			break;
		}
		repl_meta current;
		const int mr = this->_read_repl_meta(e.key, current);
		if (mr < 0) {
			break;
		}
		// Read INSIDE the critical section: the applier may have advanced it
		// while this change was waiting for a connection, a retry or a lock.
		const uint64_t cursor = this->get_repl_last_lsn();
		outcome = this->_decide_change(source_epoch, label, mr == 0, current, cursor);
		if (outcome != apply_applied) {
			break;
		}

		// Live-key accounting: probe BEFORE staging, under this key's slot
		// lock, so the count cannot drift from the key space (the forwarded
		// path used to write without touching it at all).
		bool existed = false;
		{
			string probe;
			existed = this->_db->Get(this->_read_options, this->_cf_default, e.key, &probe).ok();
		}

		rocksdb::WriteBatch batch;
		if (is_delete) {
			batch.Delete(this->_cf_default, e.key);
		} else {
			uint8_t* p = new uint8_t[entry::header_size + e.size];
			this->_serialize_header(e, p);
			if (e.size > 0 && e.data.get() != NULL) {
				memcpy(p + entry::header_size, e.data.get(), e.size);
			}
			batch.Put(this->_cf_default, e.key,
				rocksdb::Slice(reinterpret_cast<char*>(p), entry::header_size + e.size));
			delete[] p;
		}
		// The tombstone IS the metadata row: a delete leaves the key's label
		// behind so an older change is refused by the per-key test until the
		// position passes it (§3.5).
		this->_stage_repl_meta(batch, e.key, source_epoch, label, is_delete);

		// Data and metadata in ONE write: they can never disagree.
		rocksdb::Status st = this->_db->Write(this->_write_options, &batch);
		if (!this->_note_write_status(st, "apply_forwarded_change")) {
			log_err("forwarded apply failed (key=%s, label=%llu): %s",
				e.key.c_str(), (unsigned long long)label, st.ToString().c_str());
			outcome = apply_error;
			break;
		}
		// The forwarded path does NOT advance the replication cursor
		// (design §3.4): a forwarded write says nothing about what the WAL
		// has delivered, and treating it as progress would skip the range it
		// never carried.
		if (is_delete && existed) {
			this->_curr_items.decr();
		} else if (!is_delete && !existed) {
			this->_curr_items.incr();
		}
		e.seq_label = label;
	} while (0);

	pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	pthread_rwlock_unlock(&this->_repl_apply_lock);

	if (outcome == apply_applied) {
		this->_repl_forward_applied.incr();
	} else if (outcome == apply_skipped_superseded || outcome == apply_refused_cursor) {
		this->_repl_forward_skipped.incr();
	}
	return outcome;
}

namespace {
	/**
	 *	Decode a WAL WriteBatch into changes (design §3.2).
	 *
	 *	Numbering: RocksDB gives the i-th sequence-consuming entry of a batch
	 *	starting at S the sequence S+i, so entries of EVERY column family are
	 *	counted even though only the default one carries data. An operation
	 *	this decoder does not understand is not silently skipped — it would
	 *	shift every later number in the batch — it fails the whole batch.
	 */
	struct wal_decoder : public rocksdb::WriteBatch::Handler {
		struct change {
			string   key;
			string   value;
			bool     is_delete;
			uint64_t label;
		};
		vector<change> changes;
		uint64_t base_seq;
		uint64_t index;
		bool     unsupported;

		wal_decoder(uint64_t base): base_seq(base), index(0), unsupported(false) {}

		void _record(const rocksdb::Slice& key, const rocksdb::Slice* value, bool is_delete, uint32_t cf_id) {
			const uint64_t label = this->base_seq + this->index;
			this->index++;
			if (cf_id != 0) {
				return;			// another column family: numbered, not data
			}
			const string k = key.ToString();
			if (storage_rocksdb::is_reserved_key(k)) {
				return;			// reserved keys are managed explicitly (§3.6)
			}
			change c;
			c.key = k;
			c.is_delete = is_delete;
			c.label = label;
			if (value != NULL) {
				c.value = value->ToString();
			}
			this->changes.push_back(c);
		}

		rocksdb::Status PutCF(uint32_t cf, const rocksdb::Slice& key, const rocksdb::Slice& value) {
			this->_record(key, &value, false, cf);
			return rocksdb::Status::OK();
		}
		rocksdb::Status DeleteCF(uint32_t cf, const rocksdb::Slice& key) {
			this->_record(key, NULL, true, cf);
			return rocksdb::Status::OK();
		}
		rocksdb::Status SingleDeleteCF(uint32_t cf, const rocksdb::Slice& key) {
			this->_record(key, NULL, true, cf);
			return rocksdb::Status::OK();
		}
		rocksdb::Status MergeCF(uint32_t, const rocksdb::Slice&, const rocksdb::Slice&) {
			this->unsupported = true;
			this->index++;
			return rocksdb::Status::OK();
		}
		rocksdb::Status DeleteRangeCF(uint32_t, const rocksdb::Slice&, const rocksdb::Slice&) {
			this->unsupported = true;
			this->index++;
			return rocksdb::Status::OK();
		}
		void LogData(const rocksdb::Slice&) {}		// consumes no sequence
	};
}

/**
 *	Drop tombstones the applied position has passed (design §3.5).
 *
 *	A tombstone is only needed while a change older than its delete could
 *	still be admitted, and the positional rule refuses anything at or below
 *	the applied position whichever path delivered it. So once the position has
 *	passed the delete, the row can go — no wall-clock window, no assumption
 *	about how long a forwarded change can still be in flight.
 *
 *	Bounded and resumable: it runs inside the applier's exclusive window, so a
 *	large collection must not extend that window (design §3.8).
 */
uint64_t storage_rocksdb::_collect_tombstones_locked(uint64_t budget) {
	if (this->_db == NULL || this->_cf_meta == NULL || budget == 0) {
		return 0;
	}
	const uint64_t cursor = this->get_repl_last_lsn();
	rocksdb::ReadOptions ro = this->_read_options;
	ro.fill_cache = false;
	rocksdb::Iterator* it = this->_db->NewIterator(ro, this->_cf_meta);
	if (it == NULL) {
		return 0;
	}
	if (this->_tombstone_sweep_cursor.empty()) {
		it->SeekToFirst();
	} else {
		it->Seek(this->_tombstone_sweep_cursor);
	}

	rocksdb::WriteBatch batch;
	uint64_t seen = 0;
	uint64_t dropped = 0;
	string last;
	for (; it->Valid() && seen < budget; it->Next(), seen++) {
		last = it->key().ToString();
		repl_meta m;
		// Parse inline: the same format _read_repl_meta writes.
		const string v = it->value().ToString();
		string::size_type p2 = v.rfind('|');
		if (p2 == string::npos || p2 == 0) {
			continue;
		}
		string::size_type p1 = v.rfind('|', p2 - 1);
		if (p1 == string::npos) {
			continue;
		}
		if (v.substr(p2 + 1) != "1") {
			continue;					// not a tombstone
		}
		uint64_t label = 0;
		try {
			label = boost::lexical_cast<uint64_t>(v.substr(p1 + 1, p2 - p1 - 1));
		} catch (boost::bad_lexical_cast&) {
			continue;
		}
		if (label <= cursor) {
			batch.Delete(this->_cf_meta, last);
			dropped++;
		}
	}
	// Resume where this pass stopped; wrap when the family is exhausted.
	this->_tombstone_sweep_cursor = it->Valid() ? last : string("");
	delete it;

	if (dropped > 0) {
		rocksdb::Status st = this->_db->Write(this->_write_options, &batch);
		if (!st.ok()) {
			log_warning("tombstone collection failed to commit: %s", st.ToString().c_str());
			return 0;
		}
		this->_repl_tombstones_dropped.add(dropped);
	}
	return dropped;
}

uint64_t storage_rocksdb::collect_tombstones(uint64_t budget) {
	// The whole-lock is what keeps the DB handle alive: a snapshot swap, a
	// hard reset or a close takes it in write mode and destroys the handle.
	// Lock order is _repl_apply_lock -> _mutex_wholelock, as everywhere else.
	pthread_rwlock_wrlock(&this->_repl_apply_lock);
	pthread_rwlock_rdlock(&this->_mutex_wholelock);
	const uint64_t n = this->_collect_tombstones_locked(budget);
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	pthread_rwlock_unlock(&this->_repl_apply_lock);
	return n;
}

uint64_t storage_rocksdb::get_repl_tombstones() {
	pthread_rwlock_rdlock(&this->_mutex_wholelock);
	if (this->_db == NULL || this->_cf_meta == NULL) {
		pthread_rwlock_unlock(&this->_mutex_wholelock);
		return 0;
	}
	rocksdb::ReadOptions ro = this->_read_options;
	ro.fill_cache = false;
	rocksdb::Iterator* it = this->_db->NewIterator(ro, this->_cf_meta);
	if (it == NULL) {
		pthread_rwlock_unlock(&this->_mutex_wholelock);
		return 0;
	}
	uint64_t n = 0;
	for (it->SeekToFirst(); it->Valid(); it->Next()) {
		const string v = it->value().ToString();
		if (v.size() >= 2 && v.substr(v.size() - 2) == "|1") {
			n++;
		}
	}
	delete it;
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return n;
}

int storage_rocksdb::apply_wal_batch(const string& source_epoch, const string& incarnation,
		uint64_t base_seq, const rocksdb::WriteBatch& batch,
		uint64_t& applied, uint64_t& skipped, apply_outcome& refusal,
		uint64_t follow_generation) {
	applied = 0;
	skipped = 0;
	refusal = apply_applied;

	// Decoding touches no shared state and must not happen while the write
	// path is blocked (design §3.8: no work that can wait inside the
	// exclusive window; the network read happens even further out).
	wal_decoder decoder(base_seq);
	rocksdb::Status ds = batch.Iterate(&decoder);
	if (!ds.ok() || decoder.unsupported || decoder.index != batch.Count()) {
		// RELEASE-BUILD detection, not an assert: an operation we cannot
		// number or apply makes every later label in this batch wrong, so the
		// batch is refused and the caller must rebuild rather than continue.
		log_err("WAL batch at %llu refused: decode status=%s unsupported=%d decoded=%llu batch_count=%u (a change that cannot be numbered would mis-order every later one)",
			(unsigned long long)base_seq, ds.ToString().c_str(), decoder.unsupported ? 1 : 0,
			(unsigned long long)decoder.index, batch.Count());
		this->_repl_decode_refused.incr();
		refusal = apply_error;
		return -1;
	}

	const uint64_t lk0 = repl_now_us();
	pthread_rwlock_wrlock(&this->_repl_apply_lock);
	const uint64_t lk1 = repl_now_us();
	repl_atomic_max(&this->_repl_apply_lock_wait_us_max, lk1 - lk0);
	pthread_rwlock_rdlock(&this->_mutex_wholelock);

	int rc = -1;
	do {
		if (this->_db == NULL || this->_cf_meta == NULL) {
			refusal = apply_error;
			break;
		}
		// Same rule as the forwarded path: a response issued against a copy
		// this node no longer is must not be applied onto the new one. The
		// stream is long-lived, so this cannot be a connect-time check only.
		const string local_incarnation = this->get_incarnation();
		if (local_incarnation.empty() || (!incarnation.empty() && incarnation != local_incarnation)) {
			refusal = apply_refused_incarnation;
			break;
		}
		// D7: a follower stopped asynchronously may still be finishing a
		// slice after its successor started; checked under the apply lock.
		if (follow_generation != 0 && follow_generation != this->get_follow_generation()) {
			refusal = apply_refused_stale_follower;
			break;
		}
		const uint64_t cursor = this->get_repl_last_lsn();
		// Contiguity: the stream must continue where this node stopped. The
		// batch that CONTAINS the cursor is re-delivered by design (RocksDB
		// starts at the batch holding the requested sequence), so a base at
		// or below the cursor is expected; a gap is not.
		if (base_seq > cursor + 1) {
			log_err("WAL batch at %llu refused: it does not continue the applied position %llu (a gap would advance the cursor over changes that were never applied; the history in between is not being served -> this copy must be rebuilt)",
				(unsigned long long)base_seq, (unsigned long long)cursor);
			refusal = apply_refused_gap;
			break;
		}

		rocksdb::WriteBatch out;
		// In-batch overlay (design §3.8): a later change to the same key must
		// see the earlier ones of this batch, which are not in the DB yet —
		// both for the ordering decision and for the live-key count, which
		// would otherwise count the same creation twice.
		std::map<string, repl_meta> overlay;
		std::map<string, bool> exists_overlay;
		int64_t items_delta = 0;
		bool failed = false;

		for (size_t i = 0; i < decoder.changes.size(); i++) {
			const wal_decoder::change& c = decoder.changes[i];
			repl_meta current;
			bool have = false;
			std::map<string, repl_meta>::iterator it = overlay.find(c.key);
			if (it != overlay.end()) {
				current = it->second;
				have = true;
			} else {
				const int mr = this->_read_repl_meta(c.key, current);
				if (mr < 0) {
					failed = true;
					break;
				}
				have = (mr == 0);
			}

			const apply_outcome d = this->_decide_change(source_epoch, c.label, have, current, cursor);
			if (d == apply_refused_session) {
				refusal = d;
				failed = true;
				break;
			}
			if (d != apply_applied) {
				skipped++;
				continue;
			}

			bool existed = false;
			std::map<string, bool>::iterator eit = exists_overlay.find(c.key);
			if (eit != exists_overlay.end()) {
				existed = eit->second;
			} else {
				string probe;
				existed = this->_db->Get(this->_read_options, this->_cf_default, c.key, &probe).ok();
			}
			if (c.is_delete) {
				out.Delete(this->_cf_default, c.key);
				if (existed) {
					items_delta--;
				}
				exists_overlay[c.key] = false;
			} else {
				if (!existed) {
					items_delta++;
				}
				out.Put(this->_cf_default, c.key, c.value);
				exists_overlay[c.key] = true;
			}
			this->_stage_repl_meta(out, c.key, source_epoch, c.label, c.is_delete);
			repl_meta staged;
			staged.epoch = source_epoch;
			staged.label = c.label;
			staged.deleted = c.is_delete;
			overlay[c.key] = staged;
			applied++;
		}

		if (failed) {
			if (refusal == apply_applied) {
				refusal = apply_error;
			}
			break;
		}

		// The new position goes in the SAME batch as the changes it covers,
		// so a crash after applying and before recording it is impossible
		// (design §3.4). A batch in which everything was skipped still writes
		// the position, alone.
		// An empty batch covers no sequence, so it must not claim one: the
		// position may only move to a sequence this batch actually carried.
		const uint64_t new_cursor = decoder.index > 0 ? base_seq + decoder.index - 1 : cursor;
		if (new_cursor > cursor) {
			out.Put(this->_cf_default, kReplLastLsnKey, boost::lexical_cast<string>(new_cursor));
		}

		rocksdb::Status st = this->_db->Write(this->_write_options, &out);
		if (!this->_note_write_status(st, "apply_wal_batch")) {
			log_err("WAL batch at %llu failed to commit: %s", (unsigned long long)base_seq, st.ToString().c_str());
			refusal = apply_error;
			break;
		}
		if (items_delta > 0) {
			this->_curr_items.add(static_cast<uint64_t>(items_delta));
		} else if (items_delta < 0) {
			this->_curr_items.sub(static_cast<uint64_t>(-items_delta));
		}
		rc = 0;
	} while (0);

	// Tombstone GC runs INSIDE this window (design §3.8), so a tombstone can
	// never be dropped while a forwarded change admitted against an older
	// position is still between its decision and its write.
	uint64_t dropped = 0;
	if (rc == 0) {
		dropped = this->_collect_tombstones_locked(256);
	}

	pthread_rwlock_unlock(&this->_mutex_wholelock);
	{
		const uint64_t held = repl_now_us() - lk1;
		this->_repl_apply_lock_count.incr();
		this->_repl_apply_lock_hold_us.add(held);
		repl_atomic_max(&this->_repl_apply_lock_hold_us_max, held);
	}
	pthread_rwlock_unlock(&this->_repl_apply_lock);

	if (rc == 0) {
		this->_repl_wal_applied.add(applied);
		this->_repl_wal_skipped.add(skipped);
		if (dropped > 0) {
			log_debug("dropped %llu tombstone(s) the applied position has passed", (unsigned long long)dropped);
		}
	}
	return rc;
}

int storage_rocksdb::apply_batch_with_lsn(const rocksdb::WriteBatch& batch, uint64_t master_lsn) {
	if (this->_db == NULL) {
		return -1;
	}
	// Atomic LSN tracking: copy the incoming batch, append the
	// last-LSN marker update, and commit both in a single RocksDB
	// Write(). RocksDB guarantees that either the whole merged batch
	// is applied or none of it is, so a crash between "data applied"
	// and "LSN marker updated" is impossible — the slave is always
	// crash-consistent with respect to its recorded replication
	// position. See ROCKSDB_REPLICATION.md (S5) for rationale.
	rocksdb::WriteBatch merged(batch.Data());
	string lsn_value = boost::lexical_cast<string>(master_lsn);
	rocksdb::Status put_status = merged.Put(kReplLastLsnKey, lsn_value);
	if (!put_status.ok()) {
		log_err("failed to append LSN marker to batch: %s", put_status.ToString().c_str());
		return -1;
	}

	// O(1) curr_items bookkeeping (the LSN marker is a reserved key and is
	// excluded by the handler).
	curr_items_delta_handler h(this->_db, &this->_read_options);
	merged.Iterate(&h);

	rocksdb::Status status = this->_db->Write(this->_write_options, &merged);
	if (!this->_note_write_status(status, "apply_batch_with_lsn")) {
		log_err("apply_batch_with_lsn Write() failed (lsn=%llu): %s",
			(unsigned long long)master_lsn, status.ToString().c_str());
		return -1;
	}
	if (h.delta > 0) {
		this->_curr_items.add(static_cast<uint64_t>(h.delta));
	} else if (h.delta < 0) {
		this->_curr_items.sub(static_cast<uint64_t>(-h.delta));
	}
	log_debug("apply_batch_with_lsn success (lsn=%llu, batch_bytes=%zu)",
		(unsigned long long)master_lsn, batch.Data().size());
	return 0;
}

uint64_t storage_rocksdb::get_repl_last_lsn() {
	string value;

	if (this->_db == NULL) {
		return 0;
	}

	rocksdb::Status status = this->_db->Get(this->_read_options, kReplLastLsnKey, &value);
	if (status.ok()) {
		return boost::lexical_cast<uint64_t>(value);
	}

	return 0;  // No previous sync
}

int storage_rocksdb::set_repl_last_lsn(uint64_t lsn) {
	if (this->_db == NULL) {
		return -1;
	}
	// Durable, WAL-logged Put so the seeded cursor survives a crash /
	// restart just like the marker written by apply_batch_with_lsn. This
	// is how a slave reconstructed by full dump acquires a nonzero
	// replication cursor (seeded from the master's latest_lsn) so that a
	// *subsequent* WAL sync can be incremental. See handler_reconstruction.
	uint64_t old_lsn = this->get_repl_last_lsn();
	string lsn_value = boost::lexical_cast<string>(lsn);

	rocksdb::WriteOptions wo;
	wo.sync = this->_sync_writes;
	wo.disableWAL = false;
	rocksdb::Status status = this->_db->Put(wo, kReplLastLsnKey, lsn_value);
	if (!status.ok()) {
		log_err("set_repl_last_lsn Put() failed (lsn=%llu): %s",
			(unsigned long long)lsn, status.ToString().c_str());
		return -1;
	}
	log_notice("repl_last_lsn seeded: %llu -> %llu",
		(unsigned long long)old_lsn, (unsigned long long)lsn);
	return 0;
}

// Returns the current consecutive-failure streak. Held under a
// dedicated mutex because the counter supports reset-on-success, which
// AtomicCounter does not.
uint64_t storage_rocksdb::get_resync_failure_count() {
	pthread_mutex_lock(&this->_resync_failure_mutex);
	uint64_t n = this->_resync_failure_count;
	pthread_mutex_unlock(&this->_resync_failure_mutex);
	return n;
}

uint64_t storage_rocksdb::notify_resync_result(bool success) {
	pthread_mutex_lock(&this->_resync_failure_mutex);
	uint64_t old_count = this->_resync_failure_count;
	if (success) {
		this->_resync_failure_count = 0;
	} else {
		this->_resync_failure_count++;
	}
	uint64_t n = this->_resync_failure_count;
	pthread_mutex_unlock(&this->_resync_failure_mutex);
	if (success && old_count > 0) {
		log_notice("resync succeeded; failure streak reset (was %llu)",
			(unsigned long long)old_count);
	} else if (!success) {
		log_warning("resync failed; failure streak now %llu (threshold=%d)",
			(unsigned long long)n, this->_resync_failure_threshold);
	}
	return n;
}

// Snapshot the streak vs. the configured threshold. A threshold of 0
// disables self-demotion so operators can opt out of the behavior
// without recompiling.
bool storage_rocksdb::should_self_demote() {
	if (this->_resync_failure_threshold <= 0) {
		return false;
	}
	pthread_mutex_lock(&this->_resync_failure_mutex);
	bool demote = (this->_resync_failure_count >= (uint64_t)this->_resync_failure_threshold);
	pthread_mutex_unlock(&this->_resync_failure_mutex);
	return demote;
}

// Record a fresh scan result and return the token the operator must
// quote back in the follow-up `orphan_purge`. The token is a UUID so
// that it cannot be guessed or collided across processes.
string storage_rocksdb::remember_orphan_scan(uint64_t node_map_version,
                                             uint64_t orphan_count,
                                             uint64_t orphan_bytes) {
	uuid_t uuid;
	char buf[37];
	uuid_generate(uuid);
	uuid_unparse_lower(uuid, buf);

	pthread_mutex_lock(&this->_orphan_scan_mutex);
	this->_orphan_scan.token            = buf;
	this->_orphan_scan.node_map_version = node_map_version;
	this->_orphan_scan.orphan_count     = orphan_count;
	this->_orphan_scan.orphan_bytes     = orphan_bytes;
	this->_orphan_scan.issued_at        = time(NULL);
	this->_orphan_scan_valid            = true;
	string t = this->_orphan_scan.token;
	pthread_mutex_unlock(&this->_orphan_scan_mutex);
	return t;
}

bool storage_rocksdb::lookup_orphan_scan(const string& token,
                                         orphan_scan_token& out) {
	pthread_mutex_lock(&this->_orphan_scan_mutex);
	bool ok = false;
	if (this->_orphan_scan_valid && this->_orphan_scan.token == token) {
		time_t now = time(NULL);
		if (now - this->_orphan_scan.issued_at <= this->_orphan_scan_ttl_seconds) {
			out = this->_orphan_scan;
			ok = true;
		}
	}
	pthread_mutex_unlock(&this->_orphan_scan_mutex);
	return ok;
}

void storage_rocksdb::clear_orphan_scan() {
	pthread_mutex_lock(&this->_orphan_scan_mutex);
	this->_orphan_scan_valid = false;
	this->_orphan_scan.token.clear();
	pthread_mutex_unlock(&this->_orphan_scan_mutex);
}

// }}}

// {{{ named backups (checkpoints + retention)

namespace {
	// Validate a user-supplied backup name. It becomes a directory
	// component under backups/, so it must not enable path traversal or
	// escape the backups/ dir. Allowed: [A-Za-z0-9._-], non-empty, no
	// leading '.', no '/'. Returns true if safe.
	bool is_valid_backup_name(const string& name) {
		if (name.empty()) {
			return false;
		}
		if (name[0] == '.') {
			return false;
		}
		for (size_t i = 0; i < name.size(); i++) {
			char c = name[i];
			bool ok = (c >= 'A' && c <= 'Z') ||
			          (c >= 'a' && c <= 'z') ||
			          (c >= '0' && c <= '9') ||
			          c == '.' || c == '_' || c == '-';
			if (!ok) {
				return false;
			}
		}
		return true;
	}

	// Recursively delete a directory tree. Best-effort: logs but does not
	// throw. Returns 0 on success, -1 if anything could not be removed.
	int remove_tree(const string& path) {
		DIR* d = opendir(path.c_str());
		if (d == NULL) {
			// Not a directory (or gone): try a plain unlink.
			if (unlink(path.c_str()) == 0 || errno == ENOENT) {
				return 0;
			}
			return -1;
		}
		int r = 0;
		struct dirent* ent;
		while ((ent = readdir(d)) != NULL) {
			string n = ent->d_name;
			if (n == "." || n == "..") {
				continue;
			}
			string child = path + "/" + n;
			struct stat st;
			if (lstat(child.c_str(), &st) != 0) {
				r = -1;
				continue;
			}
			if (S_ISDIR(st.st_mode)) {
				if (remove_tree(child) != 0) {
					r = -1;
				}
			} else {
				if (unlink(child.c_str()) != 0 && errno != ENOENT) {
					r = -1;
				}
			}
		}
		closedir(d);
		if (rmdir(path.c_str()) != 0 && errno != ENOENT) {
			r = -1;
		}
		return r;
	}
}

int storage_rocksdb::create_named_backup(const string& name, string& out_path) {
	if (!is_valid_backup_name(name)) {
		log_err("invalid backup name [%s] (allowed: [A-Za-z0-9._-], no leading '.', no '/')", name.c_str());
		this->incr_backup_failure();
		return -1;
	}

	if (this->_db == NULL) {
		log_err("create_named_backup called before DB open", 0);
		this->incr_backup_failure();
		return -1;
	}

	const string backups_dir = this->_data_dir + "/backups";
	const string path        = backups_dir + "/" + name;

	// Ensure the backups/ parent exists (EEXIST is fine).
	if (mkdir(backups_dir.c_str(), 0700) != 0 && errno != EEXIST) {
		log_err("failed to create backups dir [%s]: %s", backups_dir.c_str(), util::strerror(errno));
		this->incr_backup_failure();
		return -1;
	}

	// Prune BEFORE creating: on a nearly-full data dir the old checkpoints
	// are exactly what blocks the new one, and a post-create prune never
	// runs when the create fails — the disk stays wedged and every later
	// hourly backup fails the same way (observed live on a tmpfs cluster).
	// Prune down to keep-1 so the new checkpoint lands exactly at keep.
	if (this->_backup_keep > 0) {
		this->_prune_named_backups(this->_backup_keep - 1);
	}

	// Free-space floor: the checkpoint hardlinks SSTs (cheap) but its
	// implied memtable flush + MANIFEST/OPTIONS/WAL copies need real space;
	// refuse early with a clean error instead of wedging mid-checkpoint.
	{
		struct statvfs vfs;
		if (statvfs(backups_dir.c_str(), &vfs) == 0) {
			const uint64_t min_free = 64ULL << 20;
			uint64_t free_bytes = static_cast<uint64_t>(vfs.f_bavail) * vfs.f_frsize;
			if (free_bytes < min_free) {
				log_err("create_named_backup refused: only %llu bytes free under %s (floor %llu)",
					(unsigned long long)free_bytes, backups_dir.c_str(), (unsigned long long)min_free);
				this->incr_backup_failure();
				return -1;
			}
		}
	}

	rocksdb::Checkpoint* cp = NULL;
	rocksdb::Status s = rocksdb::Checkpoint::Create(this->_db, &cp);
	if (!s.ok() || cp == NULL) {
		log_err("Checkpoint::Create failed: %s", s.ToString().c_str());
		this->incr_backup_failure();
		return -1;
	}

	// CreateCheckpoint requires the target directory to NOT already
	// exist; it fails otherwise. That is the behavior we want (never
	// silently overwrite an existing backup).
	s = cp->CreateCheckpoint(path);
	delete cp;
	if (!s.ok()) {
		log_err("CreateCheckpoint(%s) failed: %s", path.c_str(), s.ToString().c_str());
		this->incr_backup_failure();
		return -1;
	}

	out_path = path;
	this->incr_backup_success();
	this->_last_backup_epoch = time(NULL);
	log_notice("backup created at %s (keep=%d)", path.c_str(), this->_backup_keep);

	return 0;
}

// }}}

}   // namespace flare
}   // namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
