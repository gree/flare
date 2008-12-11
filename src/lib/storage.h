/**
 *	storage.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__STORAGE_H__
#define	__STORAGE_H__

#include <boost/shared_ptr.hpp>

#include "tcutil.h"

#include "logger.h"
#include "mm.h"
#include "util.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	storage class
 */
class storage {
public:
	enum 									option {
		option_none				= 0,
		option_noreply		= 0x01,
		option_sync				= 0x01 << 1,
	};

	enum									behavior {
		behavior_skip_lock 			= 0x01,
		behavior_skip_timestamp = 0x01 << 1,
		behavior_skip_version 	= 0x01 << 2,
		behavior_version_equal	= 0x01 << 3,
		behavior_add						= 0x01 << 4,
		behavior_replace				= 0x01 << 5,
		behavior_cas						= 0x01 << 6,
		behavior_append					= 0x01 << 7,
		behavior_prepend				= 0x01 << 8,
	};
	
	enum									result {
		result_none						= 0,
		result_stored					= 16,
		result_not_stored,
		result_exists,
		result_not_found,
		result_deleted,
		result_found,
	};

	enum									type {
		type_tch,
	};

	enum									compress {
		compress_none,
		compress_deflate,
		compress_bz2,
		compress_tcbs,
	};

	enum									hash_algorithm {
		hash_algorithm_simple = 0,
		hash_algorithm_bitshift,
	};

	enum									parse_type {
		parse_type_set,
		parse_type_cas,
		parse_type_get,
		parse_type_delete,
	};

	enum									response_type {
		response_type_get,
		response_type_gets,
		response_type_dump,
	};

	typedef struct 				_entry {
		string							key;
		uint32_t						flag;
		time_t							expire;
		uint64_t						size;
		uint64_t						version;
		uint32_t						option;
		shared_byte					data;

		static const int		header_size = sizeof(uint32_t) + sizeof(time_t) + sizeof(uint64_t) + sizeof(uint64_t);

		_entry() { flag = expire = size = version = option = 0; };

		bool is_data_available() { return this->data.get() != NULL; };

		inline int get_key_hash_value(const char* p, hash_algorithm h = hash_algorithm_simple) {
			int r = 0;
			switch (h) {
			case hash_algorithm_simple:
				while (*p) {
					r += static_cast<int>(*p);
					p++;
				}
				break;
			case hash_algorithm_bitshift:
				r = 19790217;
				while (*p) {
					r = (r << 5) + (r << 2) + r + static_cast<int>(*p);
					p++;
				}
			}
			if (r < 0) {
				r *= -1;
			}
			return r;
		}

		inline int get_key_hash_value(hash_algorithm h = hash_algorithm_simple) {
			return this->get_key_hash_value(this->key.c_str(), h);
		}

		int parse(const char* p, parse_type t) {
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

				if (t != parse_type_delete) {
					// flag
					n += util::next_digit(p+n, q, sizeof(q));
					if (q[0] == '\0') {
						log_debug("no flag found", 0);
						return -1;
					}
					this->flag = lexical_cast<uint32_t>(q);
					log_debug("storing flag [%u]", this->flag);
				}
				
				if (t != parse_type_get) {
					// expire
					n += util::next_digit(p+n, q, sizeof(q));
					if (q[0] == '\0') {
						if (t == parse_type_set) {
							log_debug("no expire found", 0);
							return -1;
						}
					} else {
						this->expire = util::realtime(lexical_cast<time_t>(q));
						log_debug("storing expire [%ld]", this->expire);
					}
				}

				if (t != parse_type_delete) {
					// size
					n += util::next_digit(p+n, q, sizeof(q));
					if (q[0] == '\0') {
						log_debug("no size found", 0);
						return -1;
					}
					this->size = lexical_cast<uint64_t>(q);
					log_debug("storing size [%u]", this->size);
				}

				// version (if we have)
				n += util::next_digit(p+n, q, sizeof(q));
				if (q[0]) {
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

		inline int response(char** p, int& len, response_type t) {
			int response_len = this->size + this->key.size() + BUFSIZ;
			*p = _new_ char[response_len];
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
	} entry;

protected:
	bool									_open;
	string								_data_dir;
	string								_data_path;
	int										_mutex_slot_size;
	pthread_rwlock_t*			_mutex_slot;
	int										_header_cache_size;
	TCMAP*								_header_cache_map;

public:
	storage(string data_dir, int mutex_slot_size, int header_cache_size);
	virtual ~storage();

	virtual int open() = 0;
	virtual int close() = 0;
	virtual int set(entry& e, result& r, int b = 0) = 0;
	virtual int incr(entry& e, uint64_t value, result& r, bool increment, int b = 0) = 0;
	virtual int get(entry& e, result& r, int b = 0) = 0;
	virtual int remove(entry& e, result& r, int b = 0) = 0;
	virtual int truncate(int b = 0) = 0;
	virtual int iter_begin() = 0;
	virtual int iter_next(string& key) = 0;
	virtual int iter_end() = 0;
	virtual uint32_t count() = 0;
	virtual uint64_t size() = 0;

	virtual type get_type() = 0;

	static inline int option_cast(string s, option& r) {
		if (s == "") {
			r = option_none;
		} else if (s == "noreply") {
			r = option_noreply;
		} else if (s == "sync") {
			r = option_sync;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string option_cast(option r) {
		switch (r) {
		case option_none:
			return "";
		case option_noreply:
			return "noreply";
		case option_sync:
			return "sync";
		}
		return "";
	};

	static inline int result_cast(string s, result& r) {
		if (s == "") {
			r = result_none;
		} else if (s == "STORED") {
			r = result_stored;
		} else if (s == "NOT_STORED") {
			r = result_not_stored;
		} else if (s == "EXISTS") {
			r = result_exists;
		} else if (s == "NOT_FOUND") {
			r = result_not_found;
		} else if (s == "DELETED") {
			r = result_deleted;
		} else if (s == "FOUND") {
			r = result_found;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string result_cast(result r) {
		switch (r) {
		case result_none:
			return "";
		case result_stored:
			return "STORED";
		case result_not_stored:
			return "NOT_STORED";
		case result_exists:
			return "EXISTS";
		case result_not_found:
			return "NOT_FOUND";
		case result_deleted:
			return "DELETED";
		case result_found:
			return "FOUND";
		}
		return "";
	};

	static inline int type_cast(string s, type& t) {
		if (s == "tch") {
			t = type_tch;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string type_cast(type t) {
		switch (t) {
		case type_tch:
			return "tch";
		}
		return "";
	};

	static inline int compress_cast(string s, compress& t) {
		if (s == "") {
			t = compress_none;
		} else if (s == "deflate") {
			t = compress_deflate;
		} else if (s == "bz2") {
			t = compress_bz2;
		} else if (s == "tcbs") {
			t = compress_tcbs;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string compress_cast(compress t) {
		switch (t) {
		case compress_none:
			return "";
		case compress_deflate:
			return "deflate";
		case compress_bz2:
			return "bz2";
		case compress_tcbs:
			return "tcbs";
		}
		return "";
	};

protected:
	virtual int _serialize_header(entry& e, uint8_t* data);
	virtual int _unserialize_header(const uint8_t* data, int data_len, entry& e);
	virtual int _get_header(string key, entry& e) = 0;
	int _set_header_cache(string key, entry& e);

	inline int _get_header_cache(string key, entry& e) {
		log_debug("get header from cache (key=%s)", key.c_str());
		int tmp_len;
		uint8_t* tmp = (uint8_t*)tcmapget(this->_header_cache_map, key.c_str(), key.size(), &tmp_len);
		if (tmp == NULL) {
			log_debug("no header in cache (key=%s)", key.c_str());
			return 0;
		}

		e.expire = *(reinterpret_cast<time_t*>(tmp));
		e.version = *(reinterpret_cast<uint64_t*>(tmp+sizeof(time_t)));
		log_debug("header from cache (key=%s, expire=%ld, version=%llu)", key.c_str(), e.expire, e.version);

		return 0;
	};

	int _gc_header_cache(int lifetime);
	int _clear_header_cache() {
		tcmapdel(this->_header_cache_map);
		this->_header_cache_map = tcmapnew();
		return 0;
	};
};

}	// namespace flare
}	// namespace gree

#endif	// __STORAGE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
