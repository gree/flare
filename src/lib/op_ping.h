/**
 *	op_ping.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_PING_H__
#define	__OP_PING_H__

#include "op.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (ping)
 */
class op_ping : public op {
protected:

public:
	op_ping(shared_connection c);
	virtual ~op_ping();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client();
	virtual int _parse_client_parameter();
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_PING_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
