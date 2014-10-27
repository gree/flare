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
#include "binary_request_header.h"
#include "binary_response_header.h"

namespace gree {
namespace flare {

const int storage::_entry::header_size;
const uint64_t storage::_entry::max_data_size;

// {{{ ctor/dtor
/**
 *	ctor for storage
 */
storage::storage(string data_dir, int mutex_slot_size, int header_cache_size):
		_open(false),
		_data_dir(data_dir),
		_mutex_slot_size(mutex_slot_size),
		_mutex_slot(NULL),
		_iter_lock(false),
		_header_cache_size(header_cache_size),
		_header_cache_map(NULL) {
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
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
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
			this->flag = boost::lexical_cast<uint32_t>(q);
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
				this->expire = util::realtime(boost::lexical_cast<time_t>(q));
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
			this->size = boost::lexical_cast<uint64_t>(q);
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
			this->version = boost::lexical_cast<uint64_t>(q);
			log_debug("storing version [%u]", this->version);
		} else if (t == parse_type_cas) {
			log_debug("no version found", 0);
			return -1;
		}

		if (t == parse_type_get) {
			// expire (if we have)
			n += util::next_digit(p+n, q, sizeof(q));
			if (q[0]) {
				this->expire = util::realtime(boost::lexical_cast<time_t>(q));
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
	} catch (boost::bad_lexical_cast e) {
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
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
