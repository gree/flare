/**
 *	op_node_remove.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_NODE_REMOVE_H
#define	OP_NODE_REMOVE_H

#include "op.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (node_remove)
 */
class op_node_remove : public op {
protected:
	cluster*	_cluster;

	string					_node_server_name;
	int							_node_server_port;

public:
	op_node_remove(shared_connection c, cluster* cl);
	virtual ~op_node_remove();

	virtual int run_client(string node_server_name, int node_server_port);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(string node_server_name, int node_server_port);
	virtual int _parse_text_client_parameters();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_NODE_REMOVE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
