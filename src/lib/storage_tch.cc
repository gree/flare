/**
 *	storage_tch.cc
 *
 *	implementation of gree::flare::storage_tch
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "storage_tch.h"

namespace gree {
namespace flare {

// {{{
// }}}

// {{{ ctor/dtor
/**
 *	ctor for storage_tch
 */
storage_tch::storage_tch(string data_dir):
		storage(data_dir) {
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
	int mutex_index = e.get_key_hash() % storage::mutex_slot;
	try {
		pthread_rwlock_wrlock(&this->_mutex_slot[mutex_index]);

		// version
	} catch (int error) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	}
	pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);

	r = result_stored;

	return 0;
}

int storage_tch::get(entry& e, result& r, int b) {
	log_info("retrieving data (key=%s)", e.key.c_str());
	int mutex_index = 0;
	uint8_t* tmp_data = NULL;
	int tmp_len = 0;
	bool remove_request = false;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash() % storage::mutex_slot;
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
			if (e.expire > 0 && e.expire < time(NULL)) {
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

		// TODO: async (lock interval can be accepted because of version control)
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
	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
