/**
 *  storage_kch.cc
 *
 *  implementation of gree::flare::storage_kch
 *
 *  @author Daniel Perez <tuvistavie@hotmail.com>
 *
 *  $Id$
 */
#include "app.h"
#include "storage_kch.h"
#include <kchashdb.h>
#include <pthread.h>

using namespace kyotocabinet;

namespace gree {
namespace flare {


// {{{ ctor/dtor
/**
 *  ctor for storage_kch
 */
storage_kch::storage_kch(string data_dir, int mutex_slot_size, uint32_t storage_ap, uint64_t storage_bucket_size, int storage_cache_size, string storage_compess, bool storage_large, int32_t storage_dfunit):
	storage(data_dir, mutex_slot_size, storage_cache_size) {
	this->_data_path = this->_data_dir + "/flare.kch";

	this->_db = new HashDB;
	compress t = compress_none;
	compress_cast(storage_compess, t);

	int tune_options = HashDB::TLINEAR;

	if (!storage_large) {
		tune_options |= HashDB::TSMALL;
	}

	this->_db->tune_buckets(storage_bucket_size);
	this->_db->tune_alignment(storage_ap);
	this->_db->tune_fbp(10);

	if (t != compress_none) {
		tune_options |= HashDB::TCOMPRESS;
		this->_db->tune_compressor(&this->_comp);
	}

	this->_db->tune_options(tune_options);

	if (storage_dfunit > 0) {
		this->_db->tune_defrag(storage_dfunit);
	}
}

/**
 *  dtor for storage
 */
storage_kch::~storage_kch() {
	if (this->_open) {
		this->close();
	}
	delete this->_db;
	this->_db = NULL;
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int storage_kch::open() {
	if (this->_open) {
		log_warning("storage has been already opened", 0);
		return -1;
	}

	if (!this->_db->open(this->_data_path, HashDB::OCREATE | HashDB::OWRITER)) {
		BasicDB::Error error = this->_db->error();
		log_err("%s failed: %s (%d)","HashDB::open()", error.message(), error.code());
		return -1;
	}

	log_debug("storage open (path=%s, type=%s)", this->_data_path.c_str(), storage::type_cast(this->_type).c_str());
	this->_open = true;

	return 0;
}

int storage_kch::close() {
	if (!this->_open) {
		log_warning("storage is not yet opened", 0);
		return -1;
	}

	if (!this->_db->close()) {
		BasicDB::Error error = this->_db->error();
		log_err("%s failed: %s (%d)","HashDB::close()", error.message(), error.code());
		return -1;
	}

	log_debug("storage close", 0);
	this->_open = false;

	return 0;
}

int storage_kch::set(entry &e, result &r, int b) {
	log_info("set (key=%s, flag=%d, expire=%ld, size=%llu, version=%llu, behavior=%x)", e.key.c_str(), e.flag, e.expire, e.size, e.version, b);
	int mutex_index = 0;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	uint8_t *p = NULL;
	try {
		if ((b & behavior_skip_lock) == 0) {
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
				log_info("specified version is older than (or equal to) current version -> skip setting (current=%u, specified=%u)", e_current.version, e.version);
				r = result_not_stored;
				throw 0;
			}
		} else if (e.version == 0) {
			e.version = e_current.version + 1;
			log_debug("updating version (version=%llu)", e.version);
		}

		// prepare data for storage
		if (b & (behavior_append | behavior_prepend)) {
			if (e_current_st != st_alive) {
				log_warning("behavior=append|prepend but no data exists -> skip setting", 0);
				throw - 1;
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
				memcpy(p + entry::header_size, e_current.data.get(), e_current.size);
				memcpy(p + entry::header_size + e_current.size, e.data.get(), e_size);
			} else {
				memcpy(p + entry::header_size, e.data.get(), e_size);
				memcpy(p + entry::header_size + e_size, e_current.data.get(), e_current.size);
			}
			shared_byte data(new uint8_t[e.size]);
			memcpy(data.get(), p + entry::header_size, e.size);
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
			memcpy(p + entry::header_size, e.data.get(), e.size);
		}

		// store in database
		if (this->_db->set(e.key.c_str(), e.key.size(), (char *)p, entry::header_size + e.size)) {
			r = result_stored;
			if (e.option & option_noreply) {
				log_debug("stored data [async] (key=%s, size=%llu)", e.key.c_str(), entry::header_size + e.size);
			} else {
				if (!this->_db->synchronize()) {
					BasicDB::Error error = this->_db->error();
					log_err("%s failed: %s (%d)", "HashDB::synchronize()", error.message(), error.code());
					throw - 1;
				}
				log_debug("stored data [sync] (key=%s, size=%llu)", e.key.c_str(), entry::header_size + e.size);
			}
		} else {
			BasicDB::Error error = this->_db->error();
			log_err("%s failed: %s (%d)", "HashDB::set()", error.message(), error.code());
			this->_listener->on_storage_error();
			throw - 1;
		}

		// "touch" commands expect result_touched
		if (b & behavior_touch
				&& r == result_stored) {
			r = result_touched;
			e.data = e_current.data;
			e.size = e_current.size;
			e.version = e_current.version;
		}
	} catch (int error) {
		delete[] p;
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		}
		return error;
	}
	delete[] p;
	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	}

	return 0;
}

int storage_kch::incr(entry &e, uint64_t value, result &r, bool increment, int b) {
	log_info("incr (key=%s, value=%llu, increment=%d", e.key.c_str(), value, increment);
	int mutex_index = 0;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	uint8_t *tmp_data = NULL;
	size_t tmp_len = 0;
	uint8_t *p = NULL;
	entry e_current;
	bool expired = false;
	try {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_wrlock(&this->_mutex_slot[mutex_index]);
		}

		// get current data (and check existence)
		tmp_data = (uint8_t *)this->_db->get(e.key.c_str(), e.key.size(), &tmp_len);
		if (tmp_data == NULL) {
			r = result_not_found;
			throw 0;
		}
		int offset = this->_unserialize_header(tmp_data, tmp_len, e_current);
		if (offset < 0) {
			log_err("failed to deserialize header (data is corrupted) (tmp_len=%d)", tmp_len);
			throw - 1;
		}
		e_current.key = e.key;
		if (static_cast<uint64_t>(tmp_len - offset) != e_current.size) {
			log_err("actual data size is different from header data size (actual=%d, header=%u)", tmp_len - offset, e_current.size);
			throw - 1;
		}
		if ((b & behavior_skip_timestamp) == 0) {
			if (e_current.expire > 0 && e_current.expire <= stats_object->get_timestamp()) {
				log_info("data expired [expire=%d] -> remove requesting", e_current.expire);
				r = result_not_found;
				expired = true;
				throw 0;
			}
		}

		// increment (or decrement)
		uint8_t *q = tmp_data + offset;
		while (*q) {
			if (isdigit(*q) == false) {
				*q = '\0';
				break;
			}
			q++;
		}

		uint64_t n = 0, m;
		try {
			n = boost::lexical_cast<uint64_t>(tmp_data + offset);
		} catch (boost::bad_lexical_cast e) {
			n = 0;
		}
		delete[] tmp_data;
		tmp_data = NULL;
		m = n + (increment ? value : -value);
		if (increment && m < n) {
			m = 0; m--;
		} else if (increment == false && m > n) {
			m = 0;
		}


		// data
		char buf[64];
		int buf_len = snprintf(buf, sizeof(buf), "%llu", static_cast<unsigned long long>(m));

		e.flag = e_current.flag;
		e.expire = e_current.expire;
		e.size = buf_len;
		e.version = e_current.version + 1;
		log_debug("updating version (version=%llu)", e.version);
		shared_byte data(new uint8_t[e.size]);
		memcpy(data.get(), buf, buf_len);
		e.data = data;

		// store
		p = new uint8_t[entry::header_size + e.size];
		this->_serialize_header(e, p);
		memcpy(p + entry::header_size, e.data.get(), e.size);

		if (this->_db->set(e.key.c_str(), e.key.size(), (char *)p, entry::header_size + e.size)) {
			r = result_stored;
			if ((e.option & option_noreply) == 0) {
				if (!this->_db->synchronize()) {
					BasicDB::Error error = this->_db->error();
					log_err("%s failed: %s (%d)", "HashDB::synchronize()", error.message(), error.code());
					throw - 1;
				}
			}
		} else {
			BasicDB::Error error = this->_db->error();
			log_err("%s failed: %s (%d)", "HashDB::set()", error.message(), error.code());
			this->_listener->on_storage_error();
			throw - 1;
		}
	} catch (int error) {
		delete[] tmp_data;
		delete[] p;
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		}

		if (expired) {
			result r_remove;
			this->remove(e_current, r_remove, (b & behavior_skip_lock) | behavior_version_equal);	  // do not care about result here
		}
		return error;
	}
	delete[] p;
	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	}

	return 0;
}

int storage_kch::get(entry &e, result &r, int b) {
	log_info("get (key=%s)", e.key.c_str());
	int mutex_index = 0;
	uint8_t *tmp_data = NULL;
	size_t tmp_len = 0;
	bool expired = false;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	try {
		if ((b & behavior_skip_lock) == 0) {
			log_debug("getting read lock (index=%d)", mutex_index);
			pthread_rwlock_rdlock(&this->_mutex_slot[mutex_index]);
		}

		tmp_data = (uint8_t *)this->_db->get(e.key.c_str(), e.key.size(), &tmp_len);

		if (tmp_data == NULL) {
			r = result_not_found;
			throw 0;
		}

		int offset = this->_unserialize_header(tmp_data, tmp_len, e);
		if (offset < 0) {
			log_err("failed to deserialize header (data is corrupted) (tmp_len=%d)", tmp_len);
			throw - 1;
		}
		if (static_cast<uint64_t>(tmp_len - offset) != e.size) {
			log_err("actual data size is different from header data size (actual=%d, header=%u)", tmp_len - offset, e.size);
			throw - 1;
		}

		if ((b & behavior_skip_timestamp) == 0) {
			if (e.expire > 0 && e.expire <= stats_object->get_timestamp()) {
				log_info("data expired [expire=%d] -> remove requesting", e.expire);
				r = result_not_found;
				expired = true;
				throw 0;
			}
		}

		shared_byte p(new uint8_t[e.size]);
		memcpy(p.get(), tmp_data + offset, tmp_len - offset);
		delete[] tmp_data;
		e.data = p;
	} catch (int error) {
		delete[] tmp_data;
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		}

		if (expired) {
			result r_remove;
			this->remove(e, r_remove, (b & behavior_skip_lock) | behavior_version_equal);	  // do not care about result here
		}

		return error;
	}
	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	}
	r = result_none;

	return 0;
}

int storage_kch::remove(entry &e, result &r, int b) {
	log_info("remove (key=%s, expire=%ld, version=%llu)", e.key.c_str(), e.expire, e.version);
	int mutex_index = 0;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	try {
		if ((b & behavior_skip_lock) == 0) {
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

		if (this->_db->remove(e.key.c_str(), e.key.size())) {
			r = expired ? result_not_found : result_deleted;
			log_debug("removed data (key=%s)", e.key.c_str());
		} else {
			BasicDB::Error error = this->_db->error();
			log_err("%s failed: %s (%d)","HashDB::remove()", error.message(), error.code());
			this->_listener->on_storage_error();
			throw - 1;
		}

		if (e.version == 0) {
			e.version = e_current.version;
		}
		this->_set_header_cache(e.key, e);
	} catch (int error) {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		}
		return error;
	}
	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	}

	return 0;
}

int storage_kch::truncate(int b) {
	log_info("truncating all data", 0);

	if ((b & behavior_skip_lock) == 0) {
		this->_mutex_slot_wrlock_all();
	}

	int r = 0;
	if (!this->_db->clear()) {
		BasicDB::Error error = this->_db->error();
		log_err("%s failed: %s (%d)", "HashDB::clear()", error.message(), error.code());
		r = -1;
	}

	this->_clear_header_cache();

	if ((b & behavior_skip_lock) == 0) {
		this->_mutex_slot_unlock_all();
	}

	return r;
}

int storage_kch::iter_begin() {
	pthread_mutex_lock(&this->_mutex_iter_lock);
	{
		if (this->_iter_lock) {
			pthread_mutex_unlock(&this->_mutex_iter_lock);
			return -1;
		}
		this->_cursor = this->_db->cursor();
		this->_iter_first = true;
		this->_iter_lock = true;
	}
	pthread_mutex_unlock(&this->_mutex_iter_lock);
	return 0;
}

storage::iteration storage_kch::iter_next(string &key) {
	pthread_mutex_lock(&this->_mutex_iter_lock);
	if (!this->_iter_lock) {
		pthread_mutex_unlock(&this->_mutex_iter_lock);
		log_warning("cursor is not initialized", 0);
		return iteration_error;
	}
	pthread_mutex_unlock(&this->_mutex_iter_lock);

	bool fetched = false;
	
	this->_mutex_slot_rdlock_all();
	{
		if (this->_iter_first) {
			this->_cursor->jump();
			this->_iter_first = false;
		} else {
			this->_cursor->step();
		}
		fetched = this->_cursor->get_key(&key);
	}
	this->_mutex_slot_unlock_all();

	if (!fetched) {
		BasicDB::Error error = this->_db->error();
		//When db is empty
		if (error.code() == BasicDB::Error::NOREC) {
			return iteration_end;
		} else {
			log_err("storage_kch::iter_next() failed: %s (%d)", error.message(), error.code());
			return iteration_error;
		}
	}

	return iteration_continue;
}

int storage_kch::iter_end() {
	pthread_mutex_lock(&this->_mutex_iter_lock);
	{
		if (!this->_iter_lock) {
			pthread_mutex_unlock(&this->_mutex_iter_lock);
			log_warning("cursor is not initialized", 0);
			return -1;
		}
		delete this->_cursor;
		this->_cursor = NULL;
		this->_iter_lock = false;
	}
	pthread_mutex_unlock(&this->_mutex_iter_lock);
	return 0;
}

uint32_t storage_kch::count() {
	return this->_db->count();
}

uint64_t storage_kch::size() {
	return this->_db->size();
}

bool storage_kch::is_capable(capability c) {
	return false;
}
// }}}

// {{{ protected methods
int storage_kch::_get_header(string key, entry &e) {
	log_debug("get header from database (key=%s)", key.c_str());
	uint8_t tmp_data[entry::header_size];
	int tmp_len = this->_db->get(key.c_str(), key.size(), (char *)tmp_data, entry::header_size);
	if (tmp_len < 0) {
		// if not found, check data version cache
		log_debug("header not found in database -> checking cache", 0);
		this->_get_header_cache(key, e);
		return -1;
	}

	int offset = this->_unserialize_header(tmp_data, tmp_len, e);
	if (offset < 0) {
		log_err("failed to deserialize header (data is corrupted) (tmp_len=%d)", tmp_len);
		return -1;
	}

	log_debug("current header from database (key=%s, flag=%u, version=%llu, expire=%ld, size=%llu)", key.c_str(), e.flag, e.version, e.expire, e.size);

	return 0;
}

// }}}

// {{{ private methods
// }}}

}   // namespace flare
}   // namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
