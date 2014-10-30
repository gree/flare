/**
 *	op_ping.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_PING_H
#define	OP_PING_H

#include "op.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (ping)
 */
class op_ping : public op {
public:
	op_ping(shared_connection c);
	virtual ~op_ping();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client();
	virtual int _parse_text_client_parameters();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PING_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
