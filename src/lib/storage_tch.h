/**
 *	storage_tch.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__STORAGE_TCH_H__
#define	__STORAGE_TCH_H__

#include <boost/shared_ptr.hpp>

#ifdef HAVE_STDLIB_H
# include <stdlib.h>
#endif // HAVE_STDLIB_H

#ifdef HAVE_STDINT_H
# include <stdint.h>
#endif // HAVE_STDINT_H

#include "tcutil.h"
#include "tchdb.h"
#include "storage.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	storage class
 */
class storage_tch : public storage {
protected:
	static const type	_type = storage::type_tch;

	string						_data_path;
	TCHDB*						_db;
	time_t						_iter_lock;

public:
	storage_tch(string data_dir, int mutex_slot_size);
	virtual ~storage_tch();

	virtual int open();
	virtual int close();
	virtual int set(entry& e, result& r, int b = 0);
	virtual int incr(entry& e, uint64_t value, result& r, bool increment, int b = 0);
	virtual int get(entry& e, result& r, int b = 0);
	virtual int remove(entry& e, result& r, int b = 0);
	virtual int truncate(int b = 0);
	virtual int iter_begin();
	virtual int iter_next(string& key);
	virtual int iter_end();
	virtual uint32_t count();
	virtual uint64_t size();

	virtual type get_type() { return this->_type; };

protected:
	virtual int _get_header(string key, entry& e);
};

}	// namespace flare
}	// namespace gree

#endif	// __STORAGE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent