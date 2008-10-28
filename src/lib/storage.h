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
		option_noreplay		= 0x01,
	};

	enum									type {
		type_tch,
	};

	typedef struct 				_entry {
		string							key;
		uint32_t						flag;
		time_t							expire;
		uint64_t						size;
		uint64_t						version;
		uint32_t						option;
		shared_byte					data;

		_entry() { flag = expire = size = version = option = 0; };
	} entry;

protected:
	bool									_open;
	string								_data_dir;
	string								_data_path;

public:
	storage(string data_dir);
	virtual ~storage();

	virtual int open() = 0;
	virtual int close() = 0;

	virtual type get_type() = 0;

	static inline int option_cast(string s, option& r) {
		if (s == "noreply") {
			r = option_noreplay;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string option_cast(option r) {
		switch (r) {
		case option_noreplay:
			return "noreply";
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
};

}	// namespace flare
}	// namespace gree

#endif	// __STORAGE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
