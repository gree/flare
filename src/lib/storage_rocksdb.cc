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
#include "storage_rocksdb.h"

#include <rocksdb/utilities/checkpoint.h>

#include <uuid/uuid.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <algorithm>
#include <map>
#include <vector>

namespace gree {
namespace flare {

// {{{ reserved keys
// Keys used by the WAL replication subsystem for per-slave metadata.
// They are hidden from get/set/remove/iter/truncate so that user-visible
// operations cannot accidentally clobber or observe them.
const char* const storage_rocksdb::kReplLastLsnKey  = "__flare_repl_last_lsn";
const char* const storage_rocksdb::kReplMasterIdKey = "__flare_repl_master_id";

bool storage_rocksdb::is_reserved_key(const string& key) {
	return key == kReplLastLsnKey || key == kReplMasterIdKey;
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
	_wal_sync_success(0),
	_wal_sync_lsn_purged(0),
	_wal_sync_lsn_ahead(0),
	_wal_sync_master_id_mismatch(0),
	_wal_sync_apply_failure(0),
	_wal_sync_other_error(0),
	_wal_sync_crc_mismatch(0),
	_wal_fallback_to_dump(0),
	_expire_reaped(0),
	_snapshot_bootstrap(0),
	_corruption_detected(0),
	_hard_reset(0),
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
	pthread_mutex_init(&this->_orphan_scan_mutex, NULL);
	pthread_rwlock_init(&this->_mutex_master_id, NULL);
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
	if (this->_db) {
		delete this->_db;
		this->_db = NULL;
	}
	pthread_mutex_destroy(&this->_resync_failure_mutex);
	pthread_mutex_destroy(&this->_orphan_scan_mutex);
	pthread_rwlock_destroy(&this->_mutex_master_id);
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
int storage_rocksdb::open() {
	if (this->_open) {
		log_warning("storage has been already opened", 0);
		return -1;
	}

	rocksdb::Status status = rocksdb::DB::Open(this->_options, this->_data_path, &this->_db);
	if (!status.ok()) {
		log_err("RocksDB::Open() failed: %s", status.ToString().c_str());
		return -1;
	}

	// Seed the O(1) curr_items counter (see storage_rocksdb.h). Exact 0 on a
	// fresh DB (nothing persisted yet — the reserved master-id key is written
	// AFTER this point and reserved keys are never counted); approximate on
	// reopen of an existing directory.
	{
		std::string est;
		uint64_t seed_count = 0;
		if (this->_db->GetProperty("rocksdb.estimate-num-keys", &est)) {
			try {
				seed_count = boost::lexical_cast<uint64_t>(est);
			} catch (boost::bad_lexical_cast&) {
				seed_count = 0;
			}
		}
		// The estimate includes our reserved replication-metadata keys on a
		// reopened DB — probe and exclude the ones actually present so a
		// small dataset is not systematically over-counted.
		std::string tmp;
		if (seed_count > 0 && this->_db->Get(this->_read_options, kReplMasterIdKey, &tmp).ok()) {
			seed_count--;
		}
		if (seed_count > 0 && this->_db->Get(this->_read_options, kReplLastLsnKey, &tmp).ok()) {
			seed_count--;
		}
		this->_curr_items.sub(this->_curr_items.fetch());
		if (seed_count > 0) {
			this->_curr_items.add(seed_count);
		}
	}

	// Establish this DB's master identity token. Must succeed; otherwise
	// the WAL replication subsystem cannot detect cross-lineage sync
	// attempts, so we fail closed.
	if (this->_load_or_generate_master_id() < 0) {
		delete this->_db;
		this->_db = NULL;
		return -1;
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

	delete this->_db;
	this->_db = NULL;

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
		if (expired) {
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
}

int storage_rocksdb::create_snapshot_checkpoint(string& out_path, uint64_t& out_seq) {
	if (this->_db == NULL) {
		log_err("create_snapshot_checkpoint called before DB open", 0);
		return -1;
	}

	// Private staging area, sibling of the DB dir. Never under backups/ so
	// the backup pruner cannot race it. Wipe any leftover from a previous
	// aborted stream, then let CreateCheckpoint create the dir itself (it
	// requires the target to not exist).
	const string path = this->_data_dir + "/snapshot.serve.tmp";
	remove_tree(path);

	rocksdb::Checkpoint* cp = NULL;
	rocksdb::Status s = rocksdb::Checkpoint::Create(this->_db, &cp);
	if (!s.ok() || cp == NULL) {
		log_err("Checkpoint::Create failed: %s", s.ToString().c_str());
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
	// Only ever remove our own staging dir — refuse anything else so a bug
	// in the caller cannot escalate into deleting the live DB.
	if (path != this->_data_dir + "/snapshot.serve.tmp") {
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
		rocksdb::Status ps = rocksdb::DB::OpenForReadOnly(probe_options, staging_dir, &probe);
		if (!ps.ok()) {
			log_err("swap_in_snapshot: staged checkpoint failed verification (open: %s) -> refusing swap", ps.ToString().c_str());
			return -1;
		}
		string tmp;
		rocksdb::Status gs = probe->Get(rocksdb::ReadOptions(), storage_rocksdb::kReplMasterIdKey, &tmp);
		delete probe;
		if (!gs.ok() && !gs.IsNotFound()) {
			log_err("swap_in_snapshot: staged checkpoint failed verification (read: %s) -> refusing swap", gs.ToString().c_str());
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
			// close the handle so the directory can be replaced.
			delete this->_db;
			this->_db = NULL;
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

		rocksdb::Status status = rocksdb::DB::Open(this->_options, this->_data_path, &this->_db);
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
			rocksdb::WriteOptions wo;
			wo.sync = this->_sync_writes;
			wo.disableWAL = false;
			string lsn_value;
			try {
				lsn_value = boost::lexical_cast<string>(checkpoint_seq);
			} catch (...) {
				lsn_value = "0";
			}
			rocksdb::Status st = this->_db->Put(wo, kReplLastLsnKey, lsn_value);
			if (!st.ok()) {
				log_err("swap_in_snapshot: failed to seed repl_last_lsn: %s", st.ToString().c_str());
				break;
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
	rocksdb::Status s = rocksdb::DB::OpenForReadOnly(opt, dir, &db);
	if (!s.ok()) {
		log_err("analyze_checkpoint: OpenForReadOnly(%s) failed: %s", dir.c_str(), s.ToString().c_str());
		return -1;
	}

	rocksdb::ReadOptions ro;
	ro.fill_cache = false;  // one-pass scan must not thrash the block cache
	rocksdb::Iterator* it = db->NewIterator(ro);
	if (it == NULL) {
		delete db;
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
	delete db;
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
	rocksdb::Status status = rocksdb::DB::Open(this->_options, this->_data_path, &this->_db);
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
			delete this->_db;
			this->_db = NULL;
		}
		if (remove_tree(this->_data_path) != 0) {
			log_err("hard_reset: failed to remove data dir [%s] -> reopen may still fail", this->_data_path.c_str());
		}
		rocksdb::Status status = rocksdb::DB::Open(this->_options, this->_data_path, &this->_db);
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
		// A fresh empty DB has no lineage; repl_last_lsn is 0, so the next
		// reconstruction takes the clean full/snapshot reseed path.
		log_notice("hard_reset: wiped and reopened empty DB [%s]; reconstruction will reseed", this->_data_path.c_str());
		r = 0;
	} while (false);
	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return r;
}

int storage_rocksdb::reap_expired(time_t now, uint32_t max_scan, const string& after_key,
		string& last_key, bool& more, uint32_t& scanned, uint32_t& reaped) {
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
				// (a concurrent set may have refreshed / un-expired the key). The
				// remove() goes through the normal write path -> RocksDB WAL ->
				// replicas. remove() takes its own per-slot lock.
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
	if (this->_db == NULL) {
		return 0;
	}
	return this->_db->GetLatestSequenceNumber();
}

int storage_rocksdb::get_updates_since(uint64_t seq_number, vector<pair<uint64_t, rocksdb::WriteBatch>>& updates) {
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

	while (iter->Valid()) {
		rocksdb::BatchResult batch = iter->GetBatch();
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
