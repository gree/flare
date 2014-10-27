/**
 *	op_version.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_VERSION_H
#define	OP_VERSION_H

#include "op.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (version)
 */
class op_version: public op {
protected:

public:
	op_version(shared_connection c);
	virtual ~op_version();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();

private:
	inline int _send_version();
	int _send_text_version();
	int _send_binary_version();
};

int op_version::_send_version() {
	return _protocol == op::text
		? _send_text_version()
		: _send_binary_version();
}

}	// namespace flare
}	// namespace gree

#endif	// OP_VERSION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
