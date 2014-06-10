/**
 *	storage.cc
 *
 *	implementation of gree::flare::storage
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "storage.h"
#include "storage_engine_interface.h"
#include "binary_request_header.h"
#include "binary_response_header.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for storage
 */
storage::storage(int mutex_slot_size, int header_cache_size, storage_engine_interface* engine, storage_listener* listener):
		_open(false),
		_mutex_slot_size(mutex_slot_size),
		_mutex_slot(NULL),
		_iter_lock(false),
		_header_cache_size(header_cache_size),
		_header_cache_map(NULL),
		_engine(engine),
		_listener(listener) {
	this->_mutex_slot = new pthread_rwlock_t[mutex_slot_size];
	int i;
	for (i = 0; i < this->_mutex_slot_size; i++) {
		pthread_rwlock_init(&this->_mutex_slot[i], NULL);
	}
	pthread_mutex_init(&_mutex_iter_lock, NULL);
	pthread_rwlock_init(&this->_mutex_header_cache_map, NULL);

	this->_header_cache_map = tcmapnew();
}

/**
 *	dtor for storage
 */
storage::~storage() {
	for (int i = 0 ; i < this->_mutex_slot_size; ++i) {
		pthread_rwlock_destroy(&_mutex_slot[i]);
	}
	delete[] this->_mutex_slot;
	this->_mutex_slot = NULL;
	pthread_mutex_destroy(&_mutex_iter_lock);
	pthread_rwlock_destroy(&_mutex_header_cache_map);

	if (this->_header_cache_map) {
		tcmapdel(this->_header_cache_map);
	}

	delete this->_engine;
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int storage::open() {
	this->_open = true;
	return this->_engine->open();
}

int storage::close() {
	this->_open = false;
	return this->_engine->close();
}

int storage::set(entry& e, result& r, int b) {
	log_info("set (key=%s, flag=%d, expire=%ld, size=%llu, version=%llu, behavior=%x)", e.key.c_str(), e.flag, e.expire, e.size, e.version, b);
	int mutex_index = 0;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	uint8_t* p = NULL;
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

		//if ((b & behavior_add)) {
			//log_notice("behavior_add: key=%s, st=%d e_cur_exists=%d", e.key.c_str(), e_current_st, e_current_exists);
		//}
		
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

		// store in database
		int ecode = this->_engine->set(e, p, entry::header_size + e.size);
		if (ecode != 0) {
			throw -1;
		}
		r = result_stored;

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

int storage::incr(entry& e, uint64_t value, result& r, bool increment, int b) {
	log_info("incr (key=%s, value=%llu, increment=%d", e.key.c_str(), value, increment);
	int mutex_index = 0;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	uint8_t* tmp_data = NULL;
	int tmp_len = 0;
	uint8_t* p = NULL;
	entry e_current;
	bool expired = false;
	try {
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_wrlock(&this->_mutex_slot[mutex_index]);
		}

		// get current data (and check existence)
		tmp_data = this->_engine->get(e.key, tmp_len);
		if (tmp_data == NULL) {
			r = result_not_found;
			throw 0;
		}
		int offset = this->_unserialize_header(tmp_data, tmp_len, e_current);
		if (offset < 0) {
			log_err("failed to deserialize header (data is corrupted) (tmp_len=%d)", tmp_len);
			throw -1;
		}
		e_current.key = e.key;
		if (static_cast<uint64_t>(tmp_len - offset) != e_current.size) {
			log_err("actual data size is different from header data size (actual=%d, header=%u)", tmp_len-offset, e_current.size);
			throw -1;
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
		uint8_t* q = tmp_data+offset;
		while (*q) {
			if (isdigit(*q) == false) {
				*q = '\0';
				break;
			}
			q++;
		}

		uint64_t n = 0, m;
		try {
			n = lexical_cast<uint64_t>(tmp_data+offset);
		} catch (bad_lexical_cast e) {
			n = 0;
		}
		free(tmp_data);
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
		e.version = e_current.version+1;
		log_debug("updating version (version=%llu)", e.version);
		shared_byte data(new uint8_t[e.size]);
		memcpy(data.get(), buf, buf_len);
		e.data = data;

		// store
		p = new uint8_t[entry::header_size + e.size];
		this->_serialize_header(e, p);
		memcpy(p+entry::header_size, e.data.get(), e.size);

		// store in database
		int ecode = this->_engine->set(e, p, entry::header_size + e.size);
		if (ecode != 0) {
			throw -1;
		}
		r = result_stored;
	} catch (int error) {
		if (tmp_data != NULL) {
			free(tmp_data);
		}
		delete[] p;
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		}

		if (expired) {
			result r_remove;
			this->remove(e_current, r_remove, (b & behavior_skip_lock) | behavior_version_equal);		// do not care about result here
		}
		return error;
	}
	delete[] p;
	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	}

	return 0;
}

int storage::get(entry& e, result& r, int b) {
	log_info("get (key=%s)", e.key.c_str());
	int mutex_index = 0;
	uint8_t* tmp_data = NULL;
	int tmp_len = 0;
	bool expired = false;

	if ((b & behavior_skip_lock) == 0) {
		mutex_index = e.get_key_hash_value(hash_algorithm_murmur) % this->_mutex_slot_size;
	}

	try {
		if ((b & behavior_skip_lock) == 0) {
			log_debug("getting read lock (index=%d)", mutex_index);
			pthread_rwlock_rdlock(&this->_mutex_slot[mutex_index]);
		}

		tmp_data = this->_engine->get(e.key, tmp_len);
		if (tmp_data == NULL) {
			r = result_not_found;
			throw 0;
		}

		int offset = this->_unserialize_header(tmp_data, tmp_len, e);
		if (offset < 0) {
			log_err("failed to deserialize header (data is corrupted) (tmp_len=%d)", tmp_len);
			throw -1;
		}
		if (static_cast<uint64_t>(tmp_len - offset) != e.size) {
			log_err("actual data size is different from header data size (actual=%d, header=%u)", tmp_len-offset, e.size);
			throw -1;
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
		free(tmp_data);
		e.data = p;
	} catch (int error) {
		if (tmp_data != NULL) {
			free(tmp_data);
		}
		if ((b & behavior_skip_lock) == 0) {
			pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
		}

		if (expired) {
			result r_remove;
			this->remove(e, r_remove, (b & behavior_skip_lock) | behavior_version_equal);		// do not care about result here
		}

		return error;
	}
	if ((b & behavior_skip_lock) == 0) {
		pthread_rwlock_unlock(&this->_mutex_slot[mutex_index]);
	}
	r = result_none;

	return 0;
}

int storage::remove(entry& e, result& r, int b) {
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

		int ecode = this->_engine->remove(e.key);
		if (ecode == 0) {
			r = expired ? result_not_found : result_deleted;
			log_debug("removed data (key=%s)", e.key.c_str());
		} else {
			throw ecode;
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

int storage::truncate(int b) {
	log_info("truncating all data", 0);

	if ((b & behavior_skip_lock) == 0) {
		this->_mutex_slot_wrlock_all();
	}

	int r = this->_engine->truncate();

	this->_clear_header_cache();

	if ((b & behavior_skip_lock) == 0) {
		this->_mutex_slot_unlock_all();
	}

	return r;
}

int storage::iter_begin() {
	pthread_mutex_lock(&this->_mutex_iter_lock);
	{
		if (this->_iter_lock) {
			pthread_mutex_unlock(&this->_mutex_iter_lock);
			return -1;
		}
		if (this->_engine->iter_begin() != 0) {
			pthread_mutex_unlock(&this->_mutex_iter_lock);
			return -1;
		}
		this->_iter_lock = true;
	}
	pthread_mutex_unlock(&this->_mutex_iter_lock);
	return 0;
}

storage::iteration storage::iter_next(string& key) {
	pthread_mutex_lock(&this->_mutex_iter_lock);
	if (!this->_iter_lock) {
		pthread_mutex_unlock(&this->_mutex_iter_lock);
		log_warning("cursor is not initialized", 0);
		return iteration_error;
	}
	pthread_mutex_unlock(&this->_mutex_iter_lock);

	storage::iteration result;

	this->_mutex_slot_rdlock_all();
	{
		result = this->_engine->iter_next(key);
	}
	this->_mutex_slot_unlock_all();

	return result;
}

int storage::iter_end() {
	pthread_mutex_lock(&this->_mutex_iter_lock);
	{
		if (!this->_iter_lock) {
			pthread_mutex_unlock(&this->_mutex_iter_lock);
			log_warning("cursor is not initialized", 0);
			return -1;
		}
		this->_iter_lock = false;
	}
	pthread_mutex_unlock(&this->_mutex_iter_lock);
	return 0;
}

uint32_t storage::count() {
	return this->_engine->count();
}

uint64_t storage::size() {
	return this->_engine->size();
}

int storage::get_key(string key, int limit, vector<string>& r) {
	if (!this->_engine->support_prefix_search()) {
		return -1;
	}
	return this->_engine->get_key_list_with_prefix(key, limit, r);
}

bool storage::is_capable(capability c) {
	switch (c) {
	case capability_prefix_search:
		return this->_engine->support_prefix_search();
	case capability_list:
		return this->_engine->support_prefix_search();
	default:
		break;
	}
	return false;
}

int storage::entry::parse(const char*p, parse_type t) {
	char q[BUFSIZ];
	try {
		// key
		int n = util::next_word(p, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("key not found", 0);
			return -1;
		}
		this->key = q;
		log_debug("storing key [%s]", this->key.c_str());

		if (t != parse_type_delete
				&& t != parse_type_touch) {
			// flag
			n += util::next_digit(p+n, q, sizeof(q));
			if (q[0] == '\0') {
				log_debug("no flag found", 0);
				return -1;
			} else if (!util::is_unsigned_integer_string(q)) {
				log_debug("invalid flag [%s]", q);
				return -1;
			}
			this->flag = lexical_cast<uint32_t>(q);
			log_debug("storing flag [%u]", this->flag);
		}
		
		if (t != parse_type_get) {
			// expire
			n += util::next_digit(p+n, q, sizeof(q));
			if (q[0] == '\0') {
				if (t == parse_type_set
						|| t == parse_type_touch) {
					log_debug("no expire found", 0);
					return -1;
				}
			} else {
				if (!util::is_unsigned_integer_string(q)) {
					log_debug("invalid expire [%s]", q);
					return -1;
				}
				this->expire = util::realtime(lexical_cast<time_t>(q));
				log_debug("storing expire [%ld]", this->expire);
			}
		}

		if (t != parse_type_delete

				&& t != parse_type_touch) {
			// size
			n += util::next_digit(p+n, q, sizeof(q));
			if (q[0] == '\0') {
				log_debug("no size found", 0);
				return -1;
			} else if (!util::is_unsigned_integer_string(q)) {
				log_debug("invalid size [%s]", q);
				return -1;
			}
			this->size = lexical_cast<uint64_t>(q);
			if (this->size > storage::entry::max_data_size) {
				log_debug("exceed maximum data size [%llu]", this->size);
				return -1;
			}
			log_debug("storing size [%llu]", this->size);
		}

		// version (if we have)
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0]) {
			if (!util::is_unsigned_integer_string(q)) {
				log_debug("invalid version [%s]", q);
				return -1;
			}
			this->version = lexical_cast<uint64_t>(q);
			log_debug("storing version [%u]", this->version);
		} else if (t == parse_type_cas) {
			log_debug("no version found", 0);
			return -1;
		}

		if (t == parse_type_get) {
			// expire (if we have)
			n += util::next_digit(p+n, q, sizeof(q));
			if (q[0]) {
				this->expire = util::realtime(lexical_cast<time_t>(q));
				log_debug("storing expire [%ld]", this->expire);
			}
		}

		if (t != parse_type_get) {
			// option
			n += util::next_word(p+n, q, sizeof(q));
			while (q[0]) {
				storage::option r = storage::option_none;
				if (storage::option_cast(q, r) < 0) {
					log_debug("unknown option [%s] (cast failed)", q);
					return -1;
				}
				this->option |= r;
				log_debug("storing option [%s -> %d]", q, r);

				n += util::next_word(p+n, q, sizeof(q));
			}
		}
	} catch (bad_lexical_cast e) {
		log_debug("invalid digit [%s]", e.what());
		return -1;
	}

	return 0;
}

int storage::entry::parse(const binary_request_header& header, const char* body) {
	if (body) {
		this->key.assign(body + header.get_extras_length(), header.get_key_length());
		this->version = header.get_cas();
		this->size = header.get_total_body_length() - header.get_key_length() - header.get_extras_length();
		return 0;
	}
	return -1;
}

int storage::entry::response(char** p, int& len, response_type t) const {
	int response_len = this->size + this->key.size() + BUFSIZ;
	*p = new char[response_len];
	len = snprintf(*p, response_len, "VALUE %s %u %llu", this->key.c_str(), this->flag, static_cast<unsigned long long>(this->size));
	if (t == response_type_gets || t == response_type_dump) {
		len += snprintf((*p)+len, response_len-len, " %llu", static_cast<unsigned long long>(this->version));
	}
	if (t == response_type_dump) {
		len += snprintf((*p)+len, response_len-len, " %ld", this->expire);
	}
	len += snprintf((*p)+len, response_len-len, "%s", line_delimiter);

	memcpy((*p)+len, this->data.get(), this->size);
	len += this->size;
	len += snprintf((*p)+len, response_len-len, "%s", line_delimiter);

	return 0;
}

int storage::entry::response(binary_response_header& header, char** body, bool prepend_key) const {
	// Compute header
	uint32_t total_body_length = 0;
	// Flag
	header.set_extras_length(sizeof(uint32_t));
	total_body_length += sizeof(uint32_t);
	// Key
	if (prepend_key) {
		header.set_key_length(this->key.size());
		total_body_length += this->key.size();
	}
	total_body_length += this->size;
	header.set_total_body_length(total_body_length);
	// Populate body
	*body = new char[total_body_length];
	// Flag
	uint32_t flag = htonl(this->flag);
	memcpy(*body, &flag, sizeof(uint32_t));
	// Key
	if (prepend_key) {
		memcpy(*body + header.get_extras_length(), this->key.data(), this->key.size());
	}
	// Value
	memcpy(*body + header.get_extras_length() + header.get_key_length(), this->data.get(), this->size);
	return 0;
}
// }}}

// {{{ protected methods
int storage::_serialize_header(entry& e, uint8_t* data) {
	int offset = 0;

	// flag
	memcpy(data+offset, &e.flag, sizeof(e.flag));
	offset += sizeof(e.flag);

	// expire
	memcpy(data+offset, &e.expire, sizeof(e.expire));
	offset += sizeof(e.expire);

	// size
	memcpy(data+offset, &e.size, sizeof(e.size));
	offset += sizeof(e.size);
	
	// version
	memcpy(data+offset, &e.version, sizeof(e.version));
	offset += sizeof(e.version);

	return 0;
}

int storage::_unserialize_header(const uint8_t* data, int data_len, entry& e) {
	int offset = 0;

	// flag
	if (static_cast<int>(offset + sizeof(e.flag)) > data_len) {
		log_warning("data is smaller than expected header size (member=flag, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.flag));
		return -1;
	}
	memcpy(&e.flag, data+offset, sizeof(e.flag));
	offset += sizeof(e.flag);

	// expire
	if (static_cast<int>(offset + sizeof(e.expire)) > data_len) {
		log_warning("data is smaller than expected header size (member=expire, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.expire));
		return -1;
	}
	memcpy(&e.expire, data+offset, sizeof(e.expire));
	offset += sizeof(e.expire);
	
	// size
	if (static_cast<int>(offset + sizeof(e.size)) > data_len) {
		log_warning("data is smaller than expected header size (member=size, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.size));
		return -1;
	}
	memcpy(&e.size, data+offset, sizeof(e.size));
	offset += sizeof(e.size);

	// version
	if (static_cast<int>(offset + sizeof(e.version)) > data_len) {
		log_warning("data is smaller than expected header size (member=version, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.version));
		return -1;
	}
	memcpy(&e.version, data+offset, sizeof(e.version));
	offset += sizeof(e.version);
	
	log_debug("unserialized (flag=%d, expire=%d, size=%llu, version=%llu)", e.flag, e.expire, e.size, e.version);

	return offset;
}

int storage::_set_header_cache(string key, entry& e) {
	log_debug("set header into cache (key=%s, expire=%ld, version=%llu)", key.c_str(), e.expire, e.version);
	uint8_t tmp[sizeof(time_t) + sizeof(uint64_t)];
	time_t* p;
	uint64_t* q;

	p = reinterpret_cast<time_t*>(tmp);
	*p = e.expire == 0 ? stats_object->get_timestamp() : e.expire;
	q = reinterpret_cast<uint64_t*>(tmp+sizeof(time_t));
	*q = e.version;

	pthread_rwlock_wrlock(&this->_mutex_header_cache_map);
	tcmapput(this->_header_cache_map, key.c_str(), key.size(), tmp, sizeof(tmp));

	// cut front here
	int n = tcmaprnum(this->_header_cache_map) - this->_header_cache_size;
	if (n > 0) {
		log_debug("cutting front cache (n=%d, current=%d, size=%d)", n, tcmaprnum(this->_header_cache_map), this->_header_cache_size);
		tcmapcutfront(this->_header_cache_map, n);
	}
	pthread_rwlock_unlock(&this->_mutex_header_cache_map);

	return 0;
};

int storage::_get_header(string key, entry& e) {
	log_debug("get header from database (key=%s)", key.c_str());

	if (this->_engine->support_get_with_buffer()) {
		uint8_t tmp_data[entry::header_size];
		int tmp_len = this->_engine->get_with_buffer(key, tmp_data, entry::header_size);
		if (this->_check_and_unserialize_header (key, e, tmp_data, tmp_len, tmp_len >= 0) != 0) {
			return -1;
		}
	} else if (this->_engine->support_get_volatile()) {
		int tmp_len = entry::header_size;
		const uint8_t* tmp_data = this->_engine->get_volatile(key, tmp_len);
		if (this->_check_and_unserialize_header (key, e, tmp_data, tmp_len, !!tmp_data) != 0) {
			return -1;
		}
	} else {
		log_err("failed to get header (cannot find good interface)", 0);
		return -1;
	}

	log_debug("current header from database (key=%s, flag=%u, version=%llu, expire=%ld, size=%llu)", key.c_str(), e.flag, e.version, e.expire, e.size);

	return 0;
}

int storage::_check_and_unserialize_header(string& key, entry& e, const uint8_t* tmp_data, int tmp_len, bool found) {
	if (!found) {
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

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
