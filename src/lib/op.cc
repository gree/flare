/**
 *	op.cc
 *
 *	implementation of gree::flare::op
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op
 */
op::op(shared_connection c, string ident):
		_connection(c),
		_ident(ident),
		_shutdown_request(false) {
}

/**
 *	dtor for op
 */
op::~op() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	process server request
 */
int op::run_server() {
	this->_thread->set_state("parse");
	if (this->_parse_server_parameter() < 0) {
		this->_send_error();
		return -1;
	}
	this->_thread->set_state("execute");
	return this->_run_server();
}
// }}}

// {{{ protected methods
/**
 *	parse request parameter
 */
int op::_parse_server_parameter() {
	return 0;
}

/**
 *	process server request
 */
int op::_run_server() {
	return 0;
}

/**
 *	send OK response
 */
int op::_send_ok() {
	log_debug("> OK", 0);
	return this->_connection->writeline("OK");
}

/**
 *	send END response
 */
int op::_send_end() {
	log_debug("> END", 0);
	return this->_connection->writeline("END");
}

/**
 *	send ERROR response
 */
int op::_send_error(error_type t, const char* m) {
	const char* r = "ERROR";
	switch (t) {
	case error_type_generic:
		r = "ERROR";
		break;
	case error_type_client:
		r = "CLIENT_ERROR";
		break;
	case error_type_server:
		r = "SERVER_ERROR";
		break;
	}
	log_debug("> %s", r);

	if (m) {
		ostringstream s;
		s << r << " " << m;
		return this->_connection->writeline(s.str().c_str());
	} else {
		return this->_connection->writeline(r);
	}
}
// }}}

// {{{ private methods
// }}}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
