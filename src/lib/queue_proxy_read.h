/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
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
 *	queue_proxy_read.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	QUEUE_PROXY_READ_H
#define	QUEUE_PROXY_READ_H

#include <list>

#include "cluster.h"
#include "storage.h"
#include "thread_queue.h"
#include "op.h"

using namespace std;

namespace gree {
namespace flare {

typedef class queue_proxy_read queue_proxy_read;
typedef boost::shared_ptr<queue_proxy_read> shared_queue_proxy_read;

/**
 *	proxy read queue class
 */
class queue_proxy_read : public thread_queue {
protected:
	cluster*								_cluster;
	storage*								_storage;
	vector<string>					_proxy;
	storage::entry					_entry;
	list<storage::entry>		_entry_list;
	void*										_parameter;
	string									_op_ident;
	op::result							_result;
	string									_result_message;

public:
	static const int max_retry = 4;

	queue_proxy_read(cluster* cl, storage* st, vector<string> proxy, storage::entry entry, void* parameter, string op_ident);
	virtual ~queue_proxy_read();

	virtual int run(shared_connection c);
	op::result get_result() { return this->_result; };
	string get_result_message() { return this->_result_message; };
	storage::entry& get_entry() { return this->_entry; };
	list<storage::entry>& get_entry_list() { return this->_entry_list; };

protected:
	op_proxy_read* _get_op(string op_ident, shared_connection c);
};

}	// namespace flare
}	// namespace gree

#endif	// QUEUE_PROXY_READ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
