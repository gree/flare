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
