/**
 *	op_quit.cc
 *
 *	implementation of gree::flare::op_quit
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_quit.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_quit
 */
op_quit::op_quit(shared_connection c):
		op(c, "quit") {
}

/**
 *	dtor for op_quit
 */
op_quit::~op_quit() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_quit::_parse_server_parameter() {
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

int op_quit::_run_server() {
	log_info("requesting shutdown", 0);
	this->_shutdown_request = true;
	
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
