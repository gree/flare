/**
 *	storage_tch.cc
 *
 *	implementation of gree::flare::storage_tch
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "storage_tch.h"

namespace gree {
namespace flare {

// {{{
// }}}

// {{{ ctor/dtor
/**
 *	ctor for storage_tch
 */
storage_tch::storage_tch(string data_dir, int mutex_slot_size):
		storage(data_dir, mutex_slot_size),
		_iter_lock(0) {
	this->_data_path = this->_data_dir + "/flare.hdb";

	this->_db = tchdbnew();
	tchdbsetmutex(this->_db);
}

/**
 *	dtor for storage
 */
storage_tch::~storage_tch() {
	if (this->_open) {
		this->close();
	}
	if (this->_db != NULL) {
		tchdbdel(this->_db);
	}
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int storage_tch::open() {
	if (this->_open) {
		log_warning("storage has been already opened", 0);
		return -1;
	}

	if (tchdbopen(this->_db, this->_data_path.c_str(), HDBOWRITER | HDBOCREAT) == false) {
		int ecode = tchdbecode(this->_db);
		log_err("tchdbopen() failed: %s (%d)", tchdberrmsg(ecode), ecode);
		return -1;
	}

	log_debug("storage open (path=%s, type=%s)", this->_data_path.c_str(), storage::type_cast(this->_type).c_str());
	this->_open = true;

	return 0;
}

int storage_tch::close() {
	if (this->_open == false) {
		log_warning("storage is not yet opened", 0);
		return -1;
	}

	if (tchdbclose(this->_db) == false) {
		int ecode = tchdbecode(this->_db);
		log_err("tchdbclose() failed: %s (%d)", tchdberrmsg(ecode), ecode);
		return -1;
	}

	log_debug("storage close", 0);
	this->_open = false;

	return 0;
}

int storage_tch::set(entry& e, result& r, int b) {
	log_info("setting data (key=%s)", e.key.c_str());
	int mutex_index = 0;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_bitshift) % this->_mutex_slot_size;
	}

	uint8_t* p = NULL;
	try {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_wrlock(&this->_mutex_slot[mutex_index]);
		}

		uint64_t version = this->_get_version(e.key);
		if ((b & behavior_skip_version) == 0 && e.version != 0) {
			if (e.version <= version) {
				log_info("specified version is older than (or equal to) current version -> skip setting (current=%u, specified=%u)", version, e.version);
				r = result_not_stored;
				throw 0;
			}
		}

		if (e.version == 0) {
			e.version = version+1;
		}
		p = _new_ uint8_t[storage::entry::header_size + e.size];
		this->_serialize_header(e, p);
		memcpy(p+storage::entry::header_size, e.data.get(), e.size);

		if (e.option & option_noreply) {
			if (tchdbputasync(this->_db, e.key.c_str(), e.key.size(), p, storage::entry::header_size + e.size) == true) {
				r = result_stored;
			} else {
				int ecode = tchdbecode(this->_db);
				log_err("tchdbputasync() failed: %s (%d)", tchdberrmsg(ecode), ecode);
				throw -1;
			}
		} else {
			if (tchdbput(this->_db, e.key.c_str(), e.key.size(), p, storage::entry::header_size + e.size) == true) {
				r = result_stored;
			} else {
				int ecode = tchdbecode(this->_db);
				log_err("tchdbputasync() failed: %s (%d)", tchdberrmsg(ecode), ecode);
				throw -1;
			}
		}
	} catch (int error) {
		if (p) {
			_delete_(p);
		}
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		}
		return error;
	}
	if (p) {
		_delete_(p);
	}
	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	}

	return 0;
}

int storage_tch::get(entry& e, result& r, int b) {
	log_info("retrieving data (key=%s)", e.key.c_str());
	int mutex_index = 0;
	uint8_t* tmp_data = NULL;
	int tmp_len = 0;
	bool remove_request = false;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_bitshift) % this->_mutex_slot_size;
	}

	try {
		if ((b & behavior_skip_lock) == 0) {
			log_debug("getting read lock (index=%d)", mutex_index);
			pthread_rwlock_rdlock(&this->_mutex_slot[mutex_index]);
		}

		tmp_data = (uint8_t*)tchdbget(this->_db, e.key.c_str(), e.key.size(), &tmp_len);
		if (tmp_data == NULL) {
			r = result_not_found;
			throw 0;
		}

		int offset = this->_unserialize_header(tmp_data, tmp_len, e);
		if (offset < 0) {
			log_err("failed to unserialize header (data is corrupted) (tmp_len=%d)", tmp_len);
			throw -1;
		}
		if (static_cast<uint64_t>(tmp_len - offset) != e.size) {
			log_err("actual data size is different from header data size (actual=%d, header=%u)", tmp_len-offset, e.size);
			throw -1;
		}

		if ((b & behavior_skip_timestamp) == 0) {
			if (e.expire > 0 && e.expire < stats_object->get_timestamp()) {
				log_info("data expired [expire=%d] -> remove requesting", e.expire);
				remove_request = true;
				throw 0;
			}
		}

		shared_byte p(new uint8_t[e.size]);
		memcpy(p.get(), tmp_data + offset, tmp_len - offset);
		free(tmp_data);
		e.data = p;
	} catch (int error) {
		if (tmp_data != NULL) {
			free(tmp_data);
		}
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		}

		if (remove_request) {
			result r_remove;
			this->remove(e, r_remove);		// do not care about result here
		}

		return error;
	}
	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	}

	return 0;
}

int storage_tch::remove(entry& e, result& r, int b) {
	log_info("removing data (key=%s)", e.key.c_str());
	int mutex_index = 0;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_bitshift) % this->_mutex_slot_size;
	}

	try {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_wrlock(&this->_mutex_slot[mutex_index]);
		}

		uint64_t version = this->_get_version(e.key);
		if ((b & behavior_skip_version) == 0 && e.version != 0) {
			if (e.version < version) {
				log_info("specified version is older than current version -> skip removing (current=%u, specified=%u)", version, e.version);
				r = result_not_found;
				throw 0;
			}
		}

		uint8_t tmp_data;
		int tmp_len = tchdbget3(this->_db, e.key.c_str(), e.key.size(), &tmp_data, 1);
		if (tmp_len < 0) {
			if (e.version != 0 && e.version > version) {
				this->_set_data_version_cache(e.key, e.version);
			}
			r = result_not_found;
			throw 0;
		}

		if (tchdbout(this->_db, e.key.c_str(), e.key.size()) == true) {
			r = result_deleted;
		} else {
			int ecode = tchdbecode(this->_db);
			log_err("tchdbout() failed: %s (%d)", tchdberrmsg(ecode), ecode);
			throw -1;
		}
		e.version = version+1;
		this->_set_data_version_cache(e.key, e.version);
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

int storage_tch::truncate(int b) {
	log_info("truncating all data", 0);

	int i;
	if ((b & behavior_skip_lock) == 0) {
		for (i = 0; i < this->_mutex_slot_size; i++) {
			pthread_rwlock_wrlock(&this->_mutex_slot[i]);
		}
	}

	int r = 0;
	if (tchdbvanish(this->_db) == false) {
			int ecode = tchdbecode(this->_db);
			log_err("tchdbvanish() failed: %s (%d)", tchdberrmsg(ecode), ecode);
			r = -1;
	}

	if ((b & behavior_skip_lock) == 0) {
		for (i = 0; i < this->_mutex_slot_size; i++) {
			pthread_rwlock_unlock(&this->_mutex_slot[i]);
		}
	}

	return r;
}

int storage_tch::iter_begin() {
	if (this->_iter_lock > 0) {
		return -1;
	}

	if (tchdbiterinit(this->_db) == false) {
		int ecode = tchdbecode(this->_db);
		log_err("tchdbiterinit() failed: %s (%d)", tchdberrmsg(ecode), ecode);
		return -1;
	}

	return 0;
}

int storage_tch::iter_next(string& key) {
	int len = 0;
	char* p = static_cast<char*>(tchdbiternext(this->_db, &len));
	if (p == NULL) {
		// end of iteration
		return -1;
	}
	key = p;
	free(p);

	return 0;
}

int storage_tch::iter_end() {
	this->_iter_lock = 0;

	return 0;
}
// }}}

// {{{ protected methods
uint64_t storage_tch::_get_version(string key) {
	uint8_t tmp_data[storage::entry::header_size];
	int tmp_len = tchdbget3(this->_db, key.c_str(), key.size(), tmp_data, storage::entry::header_size);
	if (tmp_len < 0) {
		// if not found, check data version cache
		return this->_get_data_version_cache(key);
	}

	entry e;
	int offset = this->_unserialize_header(tmp_data, tmp_len, e);
	if (offset < 0) {
		log_err("failed to unserialize header (data is corrupted) (tmp_len=%d)", tmp_len);
		return 0;
	}

	log_debug("current version (key=%s, version=%u)", key.c_str(), e.version);

	return e.version;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
