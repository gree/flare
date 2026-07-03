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

#include <uuid/uuid.h>
#include <pthread.h>

namespace gree {
namespace flare {

// {{{ reserved keys
// Keys used by the WAL replication subsystem for per-slave metadata.
// They are hidden from get/set/remove/iter/truncate so that user-visible
// operations cannot accidentally clobber or observe them.
const char* const storage_rocksdb::kReplLastLsnKey  = "__flare_repl_last_lsn";
const char* const storage_rocksdb::kReplMasterIdKey = "__flare_repl_master_id";
const char* const storage_rocksdb::kRecordCountKey  = "__flare_record_count";

bool storage_rocksdb::is_reserved_key(const string& key) {
	return key == kReplLastLsnKey || key == kReplMasterIdKey || key == kRecordCountKey;
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
	_record_count(0),
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
	_orphan_scan_ttl_seconds(300) {
	pthread_mutex_init(&this->_mutex_iter_lock, NULL);
	pthread_mutex_init(&this->_mutex_master_id, NULL);
	pthread_mutex_init(&this->_resync_failure_mutex, NULL);
	pthread_mutex_init(&this->_orphan_scan_mutex, NULL);
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
	pthread_mutex_destroy(&this->_mutex_iter_lock);
	pthread_mutex_destroy(&this->_mutex_master_id);
	pthread_mutex_destroy(&this->_resync_failure_mutex);
	pthread_mutex_destroy(&this->_orphan_scan_mutex);
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
		pthread_mutex_lock(&this->_mutex_master_id);
		this->_master_id = value;
		pthread_mutex_unlock(&this->_mutex_master_id);
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
	pthread_mutex_lock(&this->_mutex_master_id);
	this->_master_id = new_id;
	pthread_mutex_unlock(&this->_mutex_master_id);
	log_notice("generated new master id (id=%s)", new_id.c_str());
	return 0;
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
	pthread_mutex_lock(&this->_mutex_master_id);
	string old_id = this->_master_id;
	this->_master_id = id;
	pthread_mutex_unlock(&this->_mutex_master_id);
	log_notice("master id updated (old=%s, new=%s)", old_id.c_str(), id.c_str());
	return 0;
}

/**
 * Initialize the exact record counter. A clean close persists the count
 * under kRecordCountKey; load it and durably delete the marker so that a
 * crash before the next clean close forces a re-count instead of
 * trusting a stale value. Without a marker (first open or post-crash),
 * fall back to a one-time full scan.
 */
int storage_rocksdb::_load_or_count_records() {
	// the same object may be close()d and re-open()ed (tests do); start
	// from zero either way
	this->_record_count.add(-this->_record_count.fetch());

	string value;
	rocksdb::Status status = this->_db->Get(this->_read_options, kRecordCountKey, &value);
	if (status.ok()) {
		uint64_t persisted = 0;
		bool valid = true;
		try {
			persisted = boost::lexical_cast<uint64_t>(value);
		} catch (boost::bad_lexical_cast e) {
			log_warning("corrupt record count marker [%s] -> re-counting", value.c_str());
			valid = false;
		}
		rocksdb::WriteOptions wo;
		wo.sync = true;
		wo.disableWAL = false;
		rocksdb::Status del_status = this->_db->Delete(wo, kRecordCountKey);
		if (!del_status.ok()) {
			log_err("failed to clear record count marker: %s", del_status.ToString().c_str());
			return -1;
		}
		if (valid) {
			this->_record_count.add(persisted);
			log_debug("loaded persisted record count (%llu)", (unsigned long long)persisted);
			return 0;
		}
	} else if (!status.IsNotFound()) {
		log_err("failed to read record count marker: %s", status.ToString().c_str());
		return -1;
	}

	log_notice("no record count marker (first open or unclean shutdown) -> counting records", 0);
	uint64_t count = 0;
	rocksdb::Iterator* it = this->_db->NewIterator(this->_read_options);
	for (it->SeekToFirst(); it->Valid(); it->Next()) {
		if (is_reserved_key(it->key().ToString())) {
			continue;
		}
		count++;
	}
	delete it;
	this->_record_count.add(count);
	log_notice("record count initialized (%llu)", (unsigned long long)count);
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

	if (this->_load_or_count_records() < 0) {
		delete this->_db;
		this->_db = NULL;
		return -1;
	}

	log_notice("storage open (path=%s, type=%s, master_id=%s, sync_writes=%s, wal_ttl=%llus, wal_size_limit=%lluMB)",
		this->_data_path.c_str(), storage::type_cast(this->_type).c_str(), this->_master_id.c_str(),
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

	// Persist the record count so the next open() can skip the full
	// scan. Written durably; a crash before this point leaves no marker
	// and forces a re-count, which is the safe default.
	{
		rocksdb::WriteOptions wo;
		wo.sync = true;
		wo.disableWAL = false;
		string count_value = boost::lexical_cast<string>(this->_record_count.fetch());
		rocksdb::Status status = this->_db->Put(wo, kRecordCountKey, count_value);
		if (!status.ok()) {
			log_warning("failed to persist record count (next open will re-count): %s",
				status.ToString().c_str());
		}
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

		if (e_current_exists < 0) {
			// created a record that did not physically exist before
			// (append/prepend/touch never reach here with exists < 0)
			this->_record_count.incr();
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
			this->_record_count.add((uint64_t)-1);
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

		// Get current entry. Fetch even an expired record so it can be
		// physically removed below (matching storage_tcb).
		entry e_current;
		e_current.key = e.key;
		int result_code = this->get(e_current, r, behavior_skip_lock | behavior_skip_timestamp);

		if (result_code < 0 || r == result_not_found) {
			log_debug("key not found for incr/decr (key=%s)", e.key.c_str());
			r = result_not_found;
			throw 0;
		}

		if ((b & behavior_skip_timestamp) == 0 && e_current.expire > 0
				&& e_current.expire <= stats_object->get_timestamp()) {
			// Expired: remove the record (recording its version tombstone)
			// and report not found, matching storage_tcb::incr().
			log_debug("entry expired on incr/decr -> removing (key=%s, expire=%ld)",
				e.key.c_str(), e_current.expire);
			result r_remove;
			this->remove(e_current, r_remove, behavior_skip_lock | behavior_version_equal);
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

		// Perform increment/decrement. Overflow clamps to UINT64_MAX and
		// underflow clamps to 0, matching storage_tcb.
		uint64_t new_value;
		if (increment) {
			new_value = current_value + value;
			if (new_value < current_value) {
				new_value = 0;
				new_value--;
			}
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

		// Store the updated value with a single Put. Routing through
		// set() would re-read the header we already hold (a second
		// RocksDB Get of the same key under the slot lock); this mirrors
		// storage_tcb's one-get/one-put incr. The record physically
		// exists, so the record count is unchanged.
		uint8_t* p = new uint8_t[entry::header_size + e.size];
		this->_serialize_header(e, p);
		memcpy(p+entry::header_size, e.data.get(), e.size);
		rocksdb::Slice key_slice(e.key);
		rocksdb::Slice value_slice(reinterpret_cast<char*>(p), entry::header_size + e.size);
		rocksdb::Status status = this->_db->Put(this->_write_options, key_slice, value_slice);
		delete[] p;

		if (!status.ok()) {
			log_err("failed to store incr/decr result (key=%s): %s",
				e.key.c_str(), status.ToString().c_str());
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

	// Exclude every concurrent reader/writer/iteration for the duration
	// (they all hold the wholelock shared, matching storage_tcb).
	pthread_rwlock_wrlock(&this->_mutex_wholelock);

	// Full table scan delete (RocksDB doesn't have fast truncate).
	// Reserved replication metadata keys are preserved: truncating them
	// would silently break WAL sync lineage tracking on the next sync.
	// If an operator truly wants to start over they can remove the DB
	// directory. Deletes are grouped into WriteBatch chunks so the WAL
	// (and any incremental replication of it) sees a bounded number of
	// writes instead of one per key.
	rocksdb::Iterator* it = this->_db->NewIterator(this->_read_options);

	static const int truncate_batch_size = 1024;
	rocksdb::WriteBatch batch;
	int pending = 0;
	for (it->SeekToFirst(); it->Valid(); it->Next()) {
		string k = it->key().ToString();
		if (is_reserved_key(k)) {
			continue;
		}
		batch.Delete(k);
		if (++pending >= truncate_batch_size) {
			rocksdb::Status status = this->_db->Write(this->_write_options, &batch);
			if (!status.ok()) {
				log_err("RocksDB::Write() failed during truncate: %s", status.ToString().c_str());
				delete it;
				pthread_rwlock_unlock(&this->_mutex_wholelock);
				return -1;
			}
			batch.Clear();
			pending = 0;
		}
	}
	if (pending > 0) {
		rocksdb::Status status = this->_db->Write(this->_write_options, &batch);
		if (!status.ok()) {
			log_err("RocksDB::Write() failed during truncate: %s", status.ToString().c_str());
			delete it;
			pthread_rwlock_unlock(&this->_mutex_wholelock);
			return -1;
		}
	}

	delete it;

	// Reset the replicated-LSN marker: after a truncate the slave is
	// logically empty from the application's perspective and the next
	// sync should start from scratch. The master-id lineage token is
	// preserved so that incremental sync with the current master can
	// continue if appropriate.
	rocksdb::WriteOptions wo;
	wo.sync = this->_sync_writes;
	wo.disableWAL = false;
	this->_db->Delete(wo, kReplLastLsnKey);

	this->_clear_header_cache();
	this->_record_count.add(-this->_record_count.fetch());

	pthread_rwlock_unlock(&this->_mutex_wholelock);

	log_notice("storage truncated (master_id preserved=%s, repl_last_lsn reset to 0)",
		this->get_master_id().c_str());
	return 0;
}

int storage_rocksdb::iter_begin() {
	log_debug("iter_begin()", 0);

	// Serialize the busy-check and cursor setup: a shared rdlock alone
	// cannot provide mutual exclusion between two concurrent
	// iterations (dump, dump replication, orphan scan/purge, ...).
	pthread_mutex_lock(&this->_mutex_iter_lock);

	if (this->_iter_snapshot) {
		pthread_mutex_unlock(&this->_mutex_iter_lock);
		log_warning("iteration already in progress", 0);
		return -1;
	}

	// Held (shared) until iter_end() so that whole-storage operations
	// (truncate) exclude active iterations.
	pthread_rwlock_rdlock(&this->_mutex_wholelock);

	// Create snapshot for consistent iteration
	this->_iter_snapshot = this->_db->GetSnapshot();

	// Localized read options for the iterator only — do not pollute
	// this->_read_options, which is used by Get() in set()/remove()/etc.
	rocksdb::ReadOptions iter_options = this->_read_options;
	iter_options.snapshot = this->_iter_snapshot;

	this->_iter = this->_db->NewIterator(iter_options);
	this->_iter->SeekToFirst();
	this->_iter_first = true;

	pthread_mutex_unlock(&this->_mutex_iter_lock);

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

	pthread_mutex_lock(&this->_mutex_iter_lock);

	if (!this->_iter && !this->_iter_snapshot) {
		pthread_mutex_unlock(&this->_mutex_iter_lock);
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
	pthread_mutex_unlock(&this->_mutex_iter_lock);

	return 0;
}

uint32_t storage_rocksdb::count() {
	// O(1): maintained on every create/delete (see _record_count).
	// stats polls this per `stats` request, so a full scan here would
	// put a whole-DB iteration on the monitoring path.
	return static_cast<uint32_t>(this->_record_count.fetch());
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

int storage_rocksdb::get_updates_since(uint64_t seq_number, vector<pair<uint64_t, rocksdb::WriteBatch>>& updates,
		uint64_t max_total_bytes, bool* has_more) {
	if (has_more) {
		*has_more = false;
	}

	// Use RocksDB's GetUpdatesSince for WAL-based replication.
	// Semantics: the caller has applied everything up to and including
	// seq_number and wants every later update. The first returned batch
	// may overlap seq_number (RocksDB positions the iterator at the
	// batch whose range covers it); re-applying such a batch is
	// idempotent (raw Put/Delete records), so callers may either skip
	// or re-apply it.
	std::unique_ptr<rocksdb::TransactionLogIterator> iter;
	rocksdb::Status status = this->_db->GetUpdatesSince(seq_number, &iter);

	if (!status.ok()) {
		if (status.IsNotFound()) {
			// NotFound is also returned when there is simply nothing at or
			// after seq_number (e.g. a caller already at the latest
			// sequence); only report a purge when updates should exist.
			if (seq_number >= this->_db->GetLatestSequenceNumber()) {
				return 0;	// already up to date
			}
			log_warning("LSN %llu not found (purged from WAL)", seq_number);
			return ERR_LSN_PURGED;
		}
		log_err("GetUpdatesSince failed: %s", status.ToString().c_str());
		return ERR_LSN_INVALID;
	}

	// Continuity check. When the requested sequence has been purged from
	// the WAL but later WAL files remain, GetUpdatesSince() does NOT
	// return NotFound — it returns OK positioned at the first batch that
	// is still available (see rocksdb/db.h). Streaming from there would
	// silently skip the purged range, so detect the gap here and force
	// the caller onto the full-resync path instead.
	if (!iter->Valid()) {
		if (seq_number < this->_db->GetLatestSequenceNumber()) {
			log_warning("no WAL batches available after LSN %llu although latest is %llu (purged)",
				(unsigned long long)seq_number,
				(unsigned long long)this->_db->GetLatestSequenceNumber());
			return ERR_LSN_PURGED;
		}
		return 0;	// already up to date
	}

	// Accumulate batches up to max_total_bytes (0 = unlimited). At least
	// one batch that advances the caller past seq_number is always
	// included so the caller makes progress even when the budget is
	// smaller than a batch (the first batch may only overlap
	// seq_number); when the budget is exhausted `has_more` is set and
	// the caller re-fetches from the last applied sequence. This bounds
	// the memory held by a single fetch — the full WAL retention window
	// can be many GB.
	//
	// NOTE: GetBatch() MOVES the batch out of the iterator, so it must
	// be called exactly once per position — the continuity check on the
	// first batch happens inside the loop for that reason.
	uint64_t total_bytes = 0;
	bool included_progress = false;
	bool first_batch = true;
	while (iter->Valid()) {
		rocksdb::BatchResult batch = iter->GetBatch();
		if (first_batch) {
			if (batch.sequence > seq_number + 1) {
				log_warning("WAL gap detected: requested LSN %llu but first available batch starts at %llu (purged)",
					(unsigned long long)seq_number, (unsigned long long)batch.sequence);
				return ERR_LSN_PURGED;
			}
			first_batch = false;
		}
		uint64_t batch_bytes = batch.writeBatchPtr->GetDataSize();
		if (max_total_bytes > 0 && included_progress && total_bytes + batch_bytes > max_total_bytes) {
			if (has_more) {
				*has_more = true;
			}
			break;
		}
		int op_count = batch.writeBatchPtr->Count();
		uint64_t end_seq = batch.sequence + (op_count > 0 ? op_count - 1 : 0);
		// Copy the WriteBatch contents since writeBatchPtr is a unique_ptr
		updates.push_back(std::make_pair(batch.sequence, *batch.writeBatchPtr));
		total_bytes += batch_bytes;
		if (end_seq > seq_number) {
			included_progress = true;
		}
		iter->Next();
	}

	return 0;
}

namespace {
// Rebuilds an incoming replication batch without reserved metadata keys
// (a peer's master_id / repl_last_lsn / record_count markers travel in
// its WAL and must never overwrite ours) and computes the record-count
// delta the batch will cause, honoring multiple operations on the same
// key within one batch.
class replication_batch_filter : public rocksdb::WriteBatch::Handler {
public:
	rocksdb::DB* db;
	const rocksdb::ReadOptions* read_options;
	rocksdb::WriteBatch filtered;
	int64_t count_delta;
	map<string, bool> batch_state;	// key -> exists after the ops so far

	replication_batch_filter(rocksdb::DB* db, const rocksdb::ReadOptions* ro):
			db(db), read_options(ro), count_delta(0) {
	}

	virtual void Put(const rocksdb::Slice& key, const rocksdb::Slice& value) {
		string k = key.ToString();
		if (storage_rocksdb::is_reserved_key(k)) {
			return;
		}
		if (!this->_exists(k)) {
			this->count_delta++;
		}
		this->batch_state[k] = true;
		this->filtered.Put(key, value);
	}

	virtual void Delete(const rocksdb::Slice& key) {
		string k = key.ToString();
		if (storage_rocksdb::is_reserved_key(k)) {
			return;
		}
		if (this->_exists(k)) {
			this->count_delta--;
		}
		this->batch_state[k] = false;
		this->filtered.Delete(key);
	}

private:
	bool _exists(const string& k) {
		map<string, bool>::const_iterator it = this->batch_state.find(k);
		if (it != this->batch_state.end()) {
			return it->second;
		}
		string tmp;
		return this->db->Get(*this->read_options, k, &tmp).ok();
	}
};
}	// anonymous namespace

int storage_rocksdb::_apply_batch_filtered(const rocksdb::WriteBatch& batch, const string* lsn_value) {
	// Applied exclusively: replication batches touch arbitrary keys, so
	// they must not interleave with slot-locked writers (and the
	// record-count delta computed below must match the state the batch
	// is applied against).
	pthread_rwlock_wrlock(&this->_mutex_wholelock);

	replication_batch_filter filter(this->_db, &this->_read_options);
	rocksdb::Status status = const_cast<rocksdb::WriteBatch&>(batch).Iterate(&filter);
	if (!status.ok()) {
		pthread_rwlock_unlock(&this->_mutex_wholelock);
		log_err("failed to iterate replication batch: %s", status.ToString().c_str());
		return -1;
	}

	if (lsn_value) {
		// Atomic LSN tracking: the data and the last-LSN marker commit
		// in a single Write(), so a crash between "data applied" and
		// "LSN marker updated" is impossible — the destination is
		// always crash-consistent with respect to its recorded
		// replication position. See ROCKSDB_REPLICATION.md (S5).
		rocksdb::Status put_status = filter.filtered.Put(kReplLastLsnKey, *lsn_value);
		if (!put_status.ok()) {
			pthread_rwlock_unlock(&this->_mutex_wholelock);
			log_err("failed to append LSN marker to batch: %s", put_status.ToString().c_str());
			return -1;
		}
	}

	status = this->_db->Write(this->_write_options, &filter.filtered);
	if (!status.ok()) {
		pthread_rwlock_unlock(&this->_mutex_wholelock);
		log_err("replication batch Write() failed: %s", status.ToString().c_str());
		return -1;
	}
	this->_record_count.add((uint64_t)filter.count_delta);

	pthread_rwlock_unlock(&this->_mutex_wholelock);
	return 0;
}

int storage_rocksdb::apply_batch(const rocksdb::WriteBatch& batch) {
	return this->_apply_batch_filtered(batch, NULL);
}

int storage_rocksdb::apply_batch_with_lsn(const rocksdb::WriteBatch& batch, uint64_t master_lsn) {
	string lsn_value = boost::lexical_cast<string>(master_lsn);
	int r = this->_apply_batch_filtered(batch, &lsn_value);
	if (r == 0) {
		log_debug("apply_batch_with_lsn success (lsn=%llu, batch_bytes=%zu)",
			(unsigned long long)master_lsn, batch.Data().size());
	} else {
		log_err("apply_batch_with_lsn failed (lsn=%llu)", (unsigned long long)master_lsn);
	}
	return r;
}

uint64_t storage_rocksdb::get_repl_last_lsn() {
	string value;

	rocksdb::Status status = this->_db->Get(this->_read_options, kReplLastLsnKey, &value);
	if (status.ok()) {
		try {
			return boost::lexical_cast<uint64_t>(value);
		} catch (boost::bad_lexical_cast e) {
			log_err("corrupt repl_last_lsn marker [%s] -> treating as no previous sync", value.c_str());
			return 0;
		}
	}

	return 0;  // No previous sync
}

int storage_rocksdb::set_repl_last_lsn(uint64_t lsn) {
	// Persist the replication position marker durably: it is written
	// once per seed (after a full dump), not on the hot path.
	rocksdb::WriteOptions wo;
	wo.sync = true;
	wo.disableWAL = false;
	string lsn_value = boost::lexical_cast<string>(lsn);
	rocksdb::Status status = this->_db->Put(wo, kReplLastLsnKey, lsn_value);
	if (!status.ok()) {
		log_err("failed to persist repl_last_lsn=%llu: %s",
			(unsigned long long)lsn, status.ToString().c_str());
		return -1;
	}
	log_notice("repl_last_lsn set to %llu", (unsigned long long)lsn);
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

}   // namespace flare
}   // namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
