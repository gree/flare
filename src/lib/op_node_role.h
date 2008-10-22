/**
 *	op_node_role.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_NODE_ROLE_H__
#define	__OP_NODE_ROLE_H__

#include "op.h"
#include "cluster.h"

using namespace std;
using namespace boost;

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

	virtual int run_client(string node_server_name, int node_server_port, cluster::role node_role, int node_balance);

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client(string node_server_name, int node_server_port, cluster::role node_role, int node_balance);
	virtual int _parse_client_parameter();
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_NODE_ROLE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
