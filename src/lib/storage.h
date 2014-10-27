/**
 *	storage.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	STORAGE_H
#define	STORAGE_H

#include "tcutil.h"

#include "logger.h"
#include "storage_listener.h"
#include "util.h"

#include <libhashkit/hashkit.h>
#include <zlib.h>

using namespace std;

namespace gree {
namespace flare {

// Forward declarations
class binary_request_header;
class binary_response_header;

/**
 *	storage class
 */
class storage {
public:
	enum 									option {
		option_none				= 0,
		option_noreply		= 0x01,
		option_sync				= 0x01 << 1,
		option_async			= 0x01 << 2,
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
		behavior_dump						= 0x01 << 9,
		behavior_touch					= 0x01 << 10,
	};

	enum									result {
		result_none						= 0,
		result_stored					= 16,
		result_not_stored,
		result_exists,
		result_not_found,
		result_deleted,
		result_found,
		result_touched,
	};

	enum									type {
		type_tch,
		type_tcb,
		type_kch,
	};

	enum									capability {
		capability_prefix_search,
		capability_list,
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
		hash_algorithm_crc32,
		hash_algorithm_adler32,
		hash_algorithm_murmur,
		hash_algorithm_jenkins,
	};

	enum									parse_type {
		parse_type_set,
		parse_type_cas,
		parse_type_get,
		parse_type_delete,
		parse_type_touch,
	};

	enum									response_type {
		response_type_get,
		response_type_gets,
		response_type_dump,
	};

	enum									iteration {
		iteration_error = -1,
		iteration_end = 0,
		iteration_continue,
	};

	typedef struct 				_entry {
		string							key;
		uint32_t						flag;
		time_t							expire;
		uint64_t						size;
		uint64_t						version;
		uint32_t						option;
		shared_byte					data;

		static const int				header_size = sizeof(uint32_t) + sizeof(time_t) + sizeof(uint64_t) + sizeof(uint64_t);
		static const uint64_t		max_data_size = 2147483647;

		_entry() { flag = expire = size = version = option = 0; };

		bool is_data_available() const { return this->data.get() != NULL; };

		inline int get_key_hash_value(const char* p, hash_algorithm h) const {
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
				break;
			case hash_algorithm_crc32:
				// Note that the result value isn't crc32 because this function returns 31-bit value.
				// The initial value of crc32 is 0.
				r = crc32(crc32(0L, Z_NULL, 0), (const Bytef*)p, strlen(p));
				break;
			case hash_algorithm_adler32:
				// Note that the result value isn't adler32 because this function returns 31-bit value.
				// The initial value of alder is 1.
				r = adler32(adler32(0L, Z_NULL, 0), (const Bytef*)p, strlen(p));
				break;
			case hash_algorithm_murmur:
				r = libhashkit_murmur(p, strlen(p));
				break;
			case hash_algorithm_jenkins:
				r = libhashkit_jenkins(p, strlen(p));
				break;
			}
			if (r < 0) {
				r *= -1;
			}
			return r;
		}

		inline int get_key_hash_value(hash_algorithm h) const {
			return this->get_key_hash_value(this->key.c_str(), h);
		}

		int parse(const char* p, parse_type t);
		int parse(const binary_request_header& header, const char* body);
		
		int response(char** p, int& len, response_type t) const;
		int response(binary_response_header& header, char** body, bool prepend_key = false) const;
	} entry;

protected:
	bool									_open;
	string								_data_dir;
	string								_data_path;
	int										_mutex_slot_size;
	pthread_rwlock_t*			_mutex_slot;
	bool									_iter_lock;
	pthread_mutex_t				_mutex_iter_lock;
	int										_header_cache_size;
	TCMAP*								_header_cache_map;
	pthread_rwlock_t			_mutex_header_cache_map;
	storage_listener*			_listener;


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
	virtual iteration iter_next(string& key) = 0;
	virtual int iter_end() = 0;
	virtual uint32_t count() = 0;
	virtual uint64_t size() = 0;
	virtual int get_key(string key, int limit, vector<string>& r) { return -1; };

	virtual void set_listener(storage_listener* l) { this->_listener = l; };

	virtual type get_type() = 0;
	virtual bool is_capable(capability c) = 0;

	static inline int option_cast(string s, option& r) {
		if (s == "") {
			r = option_none;
		} else if (s == "noreply") {
			r = option_noreply;
		} else if (s == "sync") {
			r = option_sync;
		} else if (s == "async") {
			r = option_async;
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
		case option_async:
			return "async";
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
		} else if (s == "TOUCHED") {
			r = result_touched;
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
		case result_touched:
			return "TOUCHED";
		}
		return "";
	};

	static inline int type_cast(string s, type& t) {
		if (s == "tch") {
			t = type_tch;
		} else if (s == "tcb") {
			t = type_tcb;
		} else if (s == "kch") {
			t = type_kch;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string type_cast(type t) {
		switch (t) {
		case type_tch:
			return "tch";
		case type_tcb:
			return "tcb";
		case type_kch:
			return "kch";
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

	static inline int hash_algorithm_cast(const string& s, hash_algorithm& t) {
		if (s == "simple") {
			t = hash_algorithm_simple;
		} else if (s == "bitshift") {
			t = hash_algorithm_bitshift;
		} else if (s == "crc32") {
			t = hash_algorithm_crc32;
		} else if (s == "adler32") {
			t = hash_algorithm_adler32;
		} else if (s == "murmur") {
			t = hash_algorithm_murmur;
		} else if (s == "jenkins") {
			t = hash_algorithm_jenkins;
		} else {
			return -1;
		}
		return 0;
	}

	static inline string hash_algorithm_cast(hash_algorithm t) {
		switch (t) {
		case hash_algorithm_simple:
			return "simple";
		case hash_algorithm_bitshift:
			return "bitshift";
		case hash_algorithm_crc32:
			return "crc32";
		case hash_algorithm_adler32:
			return "adler32";
		case hash_algorithm_murmur:
			return "murmur";
		case hash_algorithm_jenkins:
			return "jenkins";
		}
		return "";
	}

protected:
	void inline _mutex_slot_rdlock_all() {
		for (int i = 0; i < this->_mutex_slot_size; i++) {
			pthread_rwlock_rdlock(&this->_mutex_slot[i]);
		}
	}

	void inline _mutex_slot_wrlock_all() {
		for (int i = 0; i < this->_mutex_slot_size; i++) {
			pthread_rwlock_wrlock(&this->_mutex_slot[i]);
		}
	}

	void inline _mutex_slot_unlock_all() {
		for (int i = this->_mutex_slot_size-1; i >= 0; i--) {
			pthread_rwlock_unlock(&this->_mutex_slot[i]);
		}
	}

	virtual int _serialize_header(entry& e, uint8_t* data);
	virtual int _unserialize_header(const uint8_t* data, int data_len, entry& e);
	virtual int _get_header(string key, entry& e) = 0;
	int _set_header_cache(string key, entry& e);

	inline int _get_header_cache(string key, entry& e) {
		log_debug("get header from cache (key=%s)", key.c_str());
		int tmp_len;

		pthread_rwlock_rdlock(&this->_mutex_header_cache_map);

		uint8_t* tmp = (uint8_t*)tcmapget(this->_header_cache_map, key.c_str(), key.size(), &tmp_len);
		if (tmp == NULL) {
			log_debug("no header in cache (key=%s)", key.c_str());
			pthread_rwlock_unlock(&this->_mutex_header_cache_map);
			return 0;
		}
		e.expire = *(reinterpret_cast<time_t*>(tmp));
		e.version = *(reinterpret_cast<uint64_t*>(tmp+sizeof(time_t)));
		log_debug("header from cache (key=%s, expire=%ld, version=%llu)", key.c_str(), e.expire, e.version);

		pthread_rwlock_unlock(&this->_mutex_header_cache_map);

		return 0;
	};

	int _clear_header_cache() {
		pthread_rwlock_wrlock(&this->_mutex_header_cache_map);
		tcmapdel(this->_header_cache_map);
		this->_header_cache_map = tcmapnew();
		pthread_rwlock_unlock(&this->_mutex_header_cache_map);

		return 0;
	};
};

}	// namespace flare
}	// namespace gree

#endif	// STORAGE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
