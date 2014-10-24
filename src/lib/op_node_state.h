/**
 *	op_node_state.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_NODE_STATE_H
#define	OP_NODE_STATE_H

#include "op.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (node_state)
 */
class op_node_state : public op {
protected:
	cluster*	_cluster;

	string					_node_server_name;
	int							_node_server_port;
	cluster::state	_node_state;

public:
	op_node_state(shared_connection c, cluster* cl);
	virtual ~op_node_state();

	virtual int run_client(string node_server_name, int node_server_port, cluster::state node_state);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(string node_server_name, int node_server_port, cluster::state node_state);
	virtual int _parse_text_client_parameters();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_NODE_STATE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
