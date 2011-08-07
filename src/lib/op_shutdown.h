/**
 *	op_shutdown.h
 *
 *	@author	Takanori Sejima <takanori.sejima@gmail.com>
 *
 *	$Id$
 */
#ifndef	__OP_SHUTDOWN_H__
#define	__OP_SHUTDOWN_H__

#include "op.h"
#include "cluster.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (node_shutdown)
 */
class op_shutdown : public op {
protected:
	cluster*	_cluster;

	string					_server_name;
	int							_server_port;

public:
	op_shutdown(shared_connection c, cluster* cl);
	virtual ~op_shutdown();

	virtual int run_client(string node_server_name, int node_server_port);

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client(string node_server_name, int node_server_port);
	virtual int _parse_client_parameter();
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_SHUTDOWN_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
