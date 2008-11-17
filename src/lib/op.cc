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
		_thread_available(false),
		_ident(ident),
		_proxy_request(false),
		_shutdown_request(false),
		_result(result_none),
		_result_message("") {
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
		this->_send_result(result_error);
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
 *	parse server response line ('\n' terminated)
 */
int op::_parse_response(const char* p, result& r, string& r_message) {
	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (op::result_cast(q, r) < 0) {
		log_warning("unknown response (p=%s)", p);
		return -1;
	}

	while (*(p+n) == ' ') {
		n++;
	}

	// skip '\n';
	if (*(p+n)) {
		string s(p+n, strlen(p+n)-1);
		r_message = s;
	}

	log_debug("(result=%s, message=%s)", result_cast(r).c_str(), r_message.c_str());

	return 0;
}

/**
 *	send result code
 */
int op::_send_result(result r, const char* message) {
	log_debug("sending result (result=%s, message=%s)", op::result_cast(r).c_str(), message ? message : "");
	if (message != NULL && *message != '\0') {
		ostringstream s;
		s << op::result_cast(r) << " " << message;
		return this->_connection->writeline(s.str().c_str());
	} else {
		return this->_connection->writeline(op::result_cast(r).c_str());
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

string op::_get_proxy_ident() {
	if (this->_proxy.size() == 0) {
		return "";
	}
	string proxy_ident = "<";
	proxy_ident += util::vector_join<string>(this->_proxy, ",");
	proxy_ident += ">";

	return proxy_ident;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
