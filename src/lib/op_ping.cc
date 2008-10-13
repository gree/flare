/**
 *	op_ping.cc
 *
 *	implementation of gree::flare::op_ping
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_ping.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_ping
 */
op_ping::op_ping(shared_connection c):
		op(c, "ping") {
}

/**
 *	dtor for op_ping
 */
op_ping::~op_ping() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_ping::_parse_server_parameter() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[1024];
	util::next_word(p, q, sizeof(q));
	if (q[0]) {
		// no arguments allowed
		log_debug("bogus string(s) found [%s] -> error", q); 
		_delete_(p);
		return -1;
	}

	_delete_(p);

	return 0;
}

int op_ping::_run_server() {
	this->_send_ok();

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
