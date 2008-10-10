/**
 *	op_quit.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_QUIT_H__
#define	__OP_QUIT_H__

#include "op.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (quit)
 */
class op_quit : public op {
protected:

public:
	op_quit(shared_connection c);
	virtual ~op_quit();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_QUIT_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
