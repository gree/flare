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
public:
	op_quit(shared_connection c);
	virtual ~op_quit();

protected:
	op_quit(shared_connection c, string ident, binary_header::opcode opcode);
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual inline int _send_text_result(result r, const char* message = NULL);
};

int op_quit::_send_text_result(result r, const char* message) {
	return 0;
}

}	// namespace flare
}	// namespace gree

#endif	// __OP_QUIT_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
