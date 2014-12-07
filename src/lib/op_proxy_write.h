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
 *	op_proxy_write.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_PROXY_WRITE_H
#define	OP_PROXY_WRITE_H

#include "op.h"
#include "cluster.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (proxy_write)
 */
class op_proxy_write : public op {
protected:
	cluster*					_cluster;
	storage*					_storage;
	storage::entry		_entry;

public:
	op_proxy_write(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	virtual ~op_proxy_write();

	virtual int run_client(storage::entry& e);

	storage::entry& get_entry() { return this->_entry; };

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(storage::entry& e);
	virtual int _parse_text_client_parameters(storage::entry& e);

	inline bool _is_sync(uint32_t option, cluster::replication cluster_option) {
		if (option & storage::option_sync) {
			return true;
		} else if (option & storage::option_async) {
			return false;
		} else if (cluster_option == cluster::replication_sync) {
			return true;
		}
		return false;
	};
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PROXY_WRITE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
