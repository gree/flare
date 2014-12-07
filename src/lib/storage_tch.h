/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * Copyright (C) Kouhei Sutou <kou@clear-code.com>
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
/**
 *	storage_tch.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	STORAGE_TCH_H
#define	STORAGE_TCH_H

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
	storage_tch(string data_dir, int mutex_slot_size, uint32_t storage_ap, uint32_t storage_fp, uint64_t storage_bucket_size, int storage_cache_size, string storage_compess, bool storage_large, int32_t storage_dfunit);
	virtual ~storage_tch();

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

	virtual type get_type() { return this->_type; };
	virtual bool is_capable(capability c);

protected:
	virtual int _get_header(string key, entry& e);
};

}	// namespace flare
}	// namespace gree

#endif	// STORAGE_TCH_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
