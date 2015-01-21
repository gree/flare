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
 *	op_node_role.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_NODE_ROLE_H
#define	OP_NODE_ROLE_H

#include "op.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (node_role)
 */
class op_node_role : public op {
protected:
	cluster*	_cluster;

	string					_node_server_name;
	int							_node_server_port;
	cluster::role		_node_role;
	int							_node_balance;
	int							_node_partition;

public:
	op_node_role(shared_connection c, cluster* cl);
	virtual ~op_node_role();

	virtual int run_client(string node_server_name, int node_server_port, cluster::role node_role, int node_balance, int node_partition);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(string node_server_name, int node_server_port, cluster::role node_role, int node_balance, int node_partition);
	virtual int _parse_text_client_parameters();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_NODE_ROLE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
