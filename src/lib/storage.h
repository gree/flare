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
		option_noreply		= 0x01,
	};

	enum									behavior {
		behavior_skip_lock = 0x01,
		behavior_skip_timestamp = 0x01 << 1,
	};
	
	enum									result {
		result_stored,
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

	static const int			mutex_slot = 64;

protected:
	bool									_open;
	string								_data_dir;
	string								_data_path;
	pthread_rwlock_t			_mutex_slot[mutex_slot];

public:
	storage(string data_dir);
	virtual ~storage();

	virtual int open() = 0;
	virtual int close() = 0;
	virtual int set(entry& e, result& r, int b = 0) = 0;
	virtual int get(entry& e, result& r, int b = 0) = 0;
	virtual int remove(entry& e, result& r, int b = 0) = 0;

	virtual type get_type() = 0;

	static inline int option_cast(string s, option& r) {
		if (s == "noreply") {
			r = option_noreply;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string option_cast(option r) {
		switch (r) {
		case option_noreply:
			return "noreply";
		}
		return "";
	};

	static inline int result_cast(string s, result& r) {
		if (s == "STORED") {
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
	virtual int _unserialize_header(const uint8_t* data, int data_len, entry& e);
};

}	// namespace flare
}	// namespace gree

#endif	// __STORAGE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
