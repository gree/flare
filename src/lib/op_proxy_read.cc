/**
 *	op_proxy_read.cc
 *
 *	implementation of gree::flare::op_proxy_read
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_proxy_read.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_proxy_read
 */
op_proxy_read::op_proxy_read(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op(c, ident, opcode),
		_cluster(cl),
		_storage(st),
		_parameter(NULL),
		_is_multiple_response(false) {
}

/**
 *	dtor for op_proxy_read
 */
op_proxy_read::~op_proxy_read() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_proxy_read::run_client(storage::entry& e, void* parameter) {
	if (this->_run_client(e, parameter) < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters(e);
}

/**
 *	send client request
 */
int op_proxy_read::run_client(list<storage::entry>& e, void* parameter) {
	if (this->_run_client(e, parameter) < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters(e);
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_proxy_read::_parse_text_server_parameters() {
	return 0;
}

int op_proxy_read::_run_server() {
	return 0;
}

int op_proxy_read::_run_client(storage::entry& e, void* parameter) {
	return 0;
}

int op_proxy_read::_run_client(list<storage::entry>& e, void* parameter) {
	return 0;
}

int op_proxy_read::_parse_text_client_parameters(storage::entry& e) {
	return 0;
}

int op_proxy_read::_parse_text_client_parameters(list<storage::entry>& e) {
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
