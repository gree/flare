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
#include "binary_response_header.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_version
 */
op_version::op_version(shared_connection c):
		op(c, "version", binary_header::opcode_version) {
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
int op_version::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	util::next_word(p, q, sizeof(q));
	if (q[0]) {
		// no arguments allowed
		log_debug("bogus string(s) found [%s] -> error", q); 
		delete[] p;
		return -1;
	}

	delete[] p;

	return 0;
}

int op_version::_run_server() {
	return _send_version();
}

int op_version::_send_text_version() {
	char buf[BUFSIZ];
	snprintf(buf, sizeof(buf), "VERSION %s-%s", PACKAGE, PACKAGE_VERSION);
	return this->_connection->writeline(buf);
}

int op_version::_send_binary_version() {
	char body[BUFSIZ];
	snprintf(body, sizeof(body), "%s-%s", PACKAGE, PACKAGE_VERSION);
	binary_response_header header(this->_opcode);
	header.set_total_body_length(strlen(body));
	return _send_binary_response(header, body);
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
