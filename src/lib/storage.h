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

	typedef struct 				_entry {
		string							key;
		int									key_hash;
		uint32_t						flag;
		time_t							expire;
		uint64_t						size;
		uint64_t						version;
		uint32_t						option;
		shared_byte					data;

		static const int		header_size = sizeof(uint32_t) + sizeof(time_t) + sizeof(uint64_t) + sizeof(uint64_t);

		_entry() { flag = expire = size = version = option = 0; key_hash = -1; };

		inline int get_key_hash() {
			if (this->key_hash >= 0) {
				return this->key_hash;
			}
			const char* p = this->key.c_str();
			this->key_hash = 0;
			while (*p) {
				this->key_hash += static_cast<int>(*p);
				p++;
			}
			return this->key_hash;
		}

		static inline int get_key_hash(string key) {
			const char* p = key.c_str();
			int n = 0;
			while (*p) {
				n += static_cast<int>(*p);
				p++;
			}
			return n;
		}
	} entry;

protected:
	bool									_open;
	string								_data_dir;
	string								_data_path;
	int										_mutex_slot_size;
	pthread_rwlock_t*			_mutex_slot;
	TCMAP*								_data_version_cache_map;

public:
	storage(string data_dir, int mutex_slot_size);
	virtual ~storage();

	virtual int open() = 0;
	virtual int close() = 0;
	virtual int set(entry& e, result& r, int b = 0) = 0;
	virtual int get(entry& e, result& r, int b = 0) = 0;
	virtual int remove(entry& e, result& r, int b = 0) = 0;

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

protected:
	virtual uint64_t _get_version(string key) = 0;
	virtual int _serialize_header(entry& e, uint8_t* data);
	virtual int _unserialize_header(const uint8_t* data, int data_len, entry& e);

	inline int _set_data_version_cache(string key, uint64_t version) {
		uint8_t tmp[sizeof(uint64_t) + sizeof(time_t)];
		uint64_t* p;
		time_t* q;

		p = reinterpret_cast<uint64_t*>(tmp);
		*p = version;
		q = reinterpret_cast<time_t*>(tmp+sizeof(uint64_t));
		*q = time(NULL);

		tcmapput(this->_data_version_cache_map, key.c_str(), key.size(), tmp, sizeof(tmp));

		return 0;
	};

	inline uint64_t _get_data_version_cache(string key) {
		int tmp_len;
		uint8_t* tmp = (uint8_t*)tcmapget(this->_data_version_cache_map, key.c_str(), key.size(), &tmp_len);
		if (tmp == NULL) {
			return 0;
		}
		log_debug("current version cache (key=%s, version=%u)", key.c_str(), *(reinterpret_cast<uint64_t*>(tmp)));

		return *(reinterpret_cast<uint64_t*>(tmp));
	};

	int _gc_data_version_cache(int lifetime);
};

}	// namespace flare
}	// namespace gree

#endif	// __STORAGE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
