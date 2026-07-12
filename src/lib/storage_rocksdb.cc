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
#include "storage_rocksdb.h"

#include <rocksdb/utilities/checkpoint.h>

#include <uuid/uuid.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <algorithm>
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
	_wal_fallback_to_dump(0),
	_resync_failure_count(0),
	_resync_failure_threshold(0),
	_wal_max_batch_bytes(0),
	_wal_sync_bwlimit(0),
	_wal_sync_interval(0),
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

		if (!status.ok()) {
			log_err("RocksDB::Put() failed: %s", status.ToString().c_str());
			r = result_not_stored;
			throw 0;
		}

		r = (b & behavior_touch) ? result_touched : result_stored;

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

	try {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_rdlock(&this->_mutex_wholelock);
			pthread_rwlock_rdlock(&this->_mutex_slot[mutex_index]);
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
			throw 0;
		}

		// Copy data
		if (e.size > 0) {
			e.data = shared_byte(new uint8_t[e.size]);
			memcpy(e.data.get(), value_ptr + entry::header_size, e.size);
		}

		r = result_none;

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
		if (status.ok()) {
			r = expired ? result_not_found : result_deleted;
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
		if (!status.ok()) {
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
	uint32_t count = 0;
	rocksdb::Iterator* it = this->_db->NewIterator(this->_read_options);

	for (it->SeekToFirst(); it->Valid(); it->Next()) {
		if (is_reserved_key(it->key().ToString())) {
			continue;
		}
		count++;
	}

	delete it;
	return count;
}

uint64_t storage_rocksdb::size() {
	uint64_t size = 0;
	std::string value;

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
	return this->_db->GetLatestSequenceNumber();
}

int storage_rocksdb::get_updates_since(uint64_t seq_number, vector<pair<uint64_t, rocksdb::WriteBatch>>& updates) {
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

int storage_rocksdb::apply_batch(const rocksdb::WriteBatch& batch) {
	// WriteBatch is passed as const reference, but Write() needs non-const pointer
	rocksdb::WriteBatch* batch_ptr = const_cast<rocksdb::WriteBatch*>(&batch);
	rocksdb::Status status = this->_db->Write(this->_write_options, batch_ptr);
	if (!status.ok()) {
		log_err("WriteBatch apply failed: %s", status.ToString().c_str());
		return -1;
	}
	return 0;
}

int storage_rocksdb::apply_batch_with_lsn(const rocksdb::WriteBatch& batch, uint64_t master_lsn) {
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

	rocksdb::Status status = this->_db->Write(this->_write_options, &merged);
	if (!status.ok()) {
		log_err("apply_batch_with_lsn Write() failed (lsn=%llu): %s",
			(unsigned long long)master_lsn, status.ToString().c_str());
		return -1;
	}
	log_debug("apply_batch_with_lsn success (lsn=%llu, batch_bytes=%zu)",
		(unsigned long long)master_lsn, batch.Data().size());
	return 0;
}

uint64_t storage_rocksdb::get_repl_last_lsn() {
	string value;

	rocksdb::Status status = this->_db->Get(this->_read_options, kReplLastLsnKey, &value);
	if (status.ok()) {
		return boost::lexical_cast<uint64_t>(value);
	}

	return 0;  // No previous sync
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

	// Prune: keep the newest _backup_keep sibling directories under
	// backups/. Names are expected to be sortable (timestamp-prefixed),
	// so lexical order == chronological order and the oldest sort first.
	if (this->_backup_keep > 0) {
		vector<string> names;
		DIR* d = opendir(backups_dir.c_str());
		if (d != NULL) {
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
		}
		if (static_cast<int>(names.size()) > this->_backup_keep) {
			sort(names.begin(), names.end());
			int to_remove = static_cast<int>(names.size()) - this->_backup_keep;
			for (int i = 0; i < to_remove; i++) {
				string victim = backups_dir + "/" + names[i];
				if (remove_tree(victim) == 0) {
					log_notice("pruned old backup %s", victim.c_str());
				} else {
					log_warning("failed to fully prune old backup %s", victim.c_str());
				}
			}
		}
	}

	return 0;
}

// }}}

}   // namespace flare
}   // namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
