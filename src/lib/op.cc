/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
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
#include "binary_request_header.h"
#include "binary_response_header.h"
#include "connection_tcp.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op
 */
op::op(shared_connection c, string ident, binary_header::opcode opcode):
		_connection(c),
		_protocol(text),
		_thread_available(false),
		_ident(ident),
		_opcode(opcode),
		_quiet(false),
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
	if (this->_parse_server_parameters() < 0) {
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

	return this->_parse_client_parameters();
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
int op::_parse_text_server_parameters() {
	return 0;
}

int op::_parse_binary_server_parameters() {
	int return_value = -1;
	const binary_request_header header(this->_connection);
	char* body = NULL;
	return_value = this->_connection->readsize(header.get_total_body_length(), &body);
	if (return_value >= 0) {
		return_value = _parse_binary_request(header, body);
	}
	delete[] body;
	return return_value;
}

int op::_parse_binary_request(const binary_request_header&, const char*) {
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
int op::_parse_text_client_parameters() {
	return 0;
}

int op::_parse_binary_client_parameters() {
	return 0;
}

/**
 *	parse server response line ('\n' terminated)
 */
int op::_parse_text_response(const char* p, result& r, string& r_message) {
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
int op::_send_text_result(result r, const char* message) {
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
 *	send result code
 */
int op::_send_binary_result(result r, const char* message) {
	binary_header::status status;
	switch (r) {
		case result_none:
		case result_ok:
		case result_end:
		case result_stored:
		case result_deleted:
		case result_found:
		case result_touched:
			status = binary_header::status_no_error;
			break;
		case result_not_stored:
			status = binary_header::status_item_not_stored;
			message = "Item not stored";
			break;
		case result_exists:
			status = binary_header::status_key_exists;
			message = "Key exists";
			break;
		case result_not_found:
			status = binary_header::status_key_not_found;
			message = "Not found";
			break;
		case result_error:
		case result_client_error:
		case result_server_error:
		default:
			status = binary_header::status_internal_error; // Temporary
			break;
	}
	if (!_quiet
			|| status != binary_header::status_no_error) {
		binary_response_header header(this->_opcode);
		header.set_status(status);
		uint32_t total_body_length = message ? strlen(message) : 0;
		if (total_body_length == 0) {
			const std::string& default_message = binary_header::status_cast(status);
			header.set_total_body_length(default_message.size());
			return _send_binary_response(header, default_message.data());
		} else {
			header.set_total_body_length(total_body_length);
			return _send_binary_response(header, message);
		}
	}
	return 0;
}

int op::_send_binary_response(const binary_response_header& header, const char* body, bool buffer) {
	std::ostringstream s;
	s.write(header.get_raw_data(), header.get_raw_size());
	int total_body_length = header.get_total_body_length();
	if (total_body_length) {
		s.write(body, total_body_length);
	}
	return this->_connection->write(s.str().c_str(), header.get_raw_size() + total_body_length, buffer);
}

/**
 *	send request
 */
int op::_send_request(const char* request) {
	// add proxy identifier if we need
#ifdef DEBUG
	if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(this->_connection.get())) {
		log_info("sending request [%s] (host=%s, port=%d)", request, ctp->get_host().c_str(), ctp->get_port());
	}
#endif
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
