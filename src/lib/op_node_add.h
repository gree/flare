/**
 *	op_node_add.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_NODE_ADD_H__
#define	__OP_NODE_ADD_H__

#include "op.h"
#include "cluster.h"

using namespace std;
using namespace boost;

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
	op_node_add(shared_connection c, cluster* p);
	virtual ~op_node_add();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client();
	virtual int _parse_client_parameter();
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_NODE_ADD_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
