/**
 *	storage_tcb.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	STORAGE_TCB_H
#define	STORAGE_TCB_H

#ifdef HAVE_STDLIB_H
# include <stdlib.h>
#endif // HAVE_STDLIB_H

#ifdef HAVE_STDINT_H
# include <stdint.h>
#endif // HAVE_STDINT_H

#include "tcutil.h"
#include "tcbdb.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	storage class
 */
class storage_tcb : public storage {
protected:
	static const type	_type = storage::type_tcb;

	string						_data_path;
	TCBDB*						_db;
	BDBCUR*						_cursor;

public:
	storage_tcb(string data_dir, int mutex_slot_size, uint32_t storage_ap, uint32_t storage_fp, uint64_t storage_bucket_size, int storage_cache_size, string storage_compess, bool storage_large, int storage_lmemb, int storage_nmemb, int32_t storage_dfunit);
	virtual ~storage_tcb();

	virtual int open();
	virtual int close();
	virtual int set(entry& e, result& r, int b = 0);
	virtual int incr(entry& e, uint64_t value, result& r, bool increment, int b = 0);
	virtual int get(entry& e, result& r, int b = 0);
	virtual int remove(entry& e, result& r, int b = 0);
	virtual int truncate(int b = 0);
	virtual int iter_begin();
	virtual iteration iter_next(string& key);
	virtual int iter_end();
	virtual uint32_t count();
	virtual uint64_t size();
	virtual int get_key(string key, int limit, vector<string>& r);

	virtual type get_type() { return this->_type; };
	virtual bool is_capable(capability c);

protected:
	virtual int _get_header(string key, entry& e);

private:
	bool _iter_first;
};

}	// namespace flare
}	// namespace gree

#endif	// STORAGE_TCB_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
