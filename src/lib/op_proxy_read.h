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
 *	op_proxy_read.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_PROXY_READ_H
#define	OP_PROXY_READ_H

#include <list>

#include "op.h"
#include "cluster.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (proxy_read)
 */
class op_proxy_read : public op {
protected:
	cluster*							_cluster;
	storage*							_storage;
	list<storage::entry>	_entry_list;
	void*									_parameter;
	bool									_is_multiple_response;

public:
	op_proxy_read(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	virtual ~op_proxy_read();

	bool is_multiple_response() { return this->_is_multiple_response; };

	virtual int run_client(storage::entry& e, void* parameter);
	virtual int run_client(list<storage::entry>& entry_list, void* parameter);

	list<storage::entry>& get_entry_list() { return this->_entry_list; };

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(storage::entry& e, void* parameter);
	virtual int _run_client(list<storage::entry>& e, void* parameter);
	virtual int _parse_text_client_parameters(storage::entry& e);
	virtual int _parse_text_client_parameters(list<storage::entry>& e);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PROXY_READ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
