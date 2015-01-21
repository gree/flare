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
 *	op_node_add.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_NODE_ADD_H
#define	OP_NODE_ADD_H

#include "op.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (node_add)
 */
class op_node_add : public op {
protected:
	cluster*	_cluster;

	string		_node_server_name;
	int				_node_server_port;

public:
	op_node_add(shared_connection c, cluster* cl);
	virtual ~op_node_add();

	virtual int run_client(vector<cluster::node>& v);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client();
	virtual int _parse_text_client_parameters(vector<cluster::node>& v);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_NODE_ADD_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
