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
		_proxy_request(false),
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

/**
 *	send client request
 */
int op::run_client() {
	if (this->_run_client() < 0) {
		return -1;
	}

	return this->_parse_client_parameter();
}

/**
 *	set proxied node list
 */
int op::set_proxy(string proxy) {
	this->_proxy = util::vector_split<string>(proxy, ",");
	this->_proxy_request = true;

	log_debug("seems to be proxy request -> storing proxied node list (proxy=%s, n=%d)", proxy.c_str(), this->_proxy.size());

	return 0;
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
 *	send client request
 */
int op::_run_client() {
	return 0;
}

/**
 *	parse server response
 */
int op::_parse_client_parameter() {
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

/**
 *	send request
 */
int op::_send_request(const char* request) {
	// add proxy identifier if we need
	
	log_info("sending request [%s] (host=%s, port=%d)", request, this->_connection->get_host().c_str(), this->_connection->get_port());
	return this->_connection->writeline(request);
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
