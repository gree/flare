/**
 *	op_version.cc
 *
 *	implementation of gree::flare::op_version
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_version.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_version
 */
op_version::op_version(shared_connection c):
		op(c, "version") {
}

/**
 *	dtor for op_version
 */
op_version::~op_version() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_version::_parse_server_parameter() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
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

int op_version::_run_server() {
	char buf[BUFSIZ];
	snprintf(buf, sizeof(buf), "VERSION %s", PACKAGE_VERSION);
	this->_connection->writeline(buf);

	return 0;
}
// }}}

// {{{ private methods
// }}}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
