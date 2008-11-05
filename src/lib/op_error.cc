/**
 *	op_error.cc
 *
 *	implementation of gree::flare::op_error
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_error.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_error
 */
op_error::op_error(shared_connection c):
		op(c, "error") {
}

/**
 *	dtor for op_error
 */
op_error::~op_error() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_error::_parse_server_parameter() {
	// consume 1 line anyway...
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	_delete_(p);

	return 0;
}

int op_error::_run_server() {
	this->_send_result(result_error);

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
