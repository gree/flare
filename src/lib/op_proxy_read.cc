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
op_proxy_read::op_proxy_read(shared_connection c, string ident, cluster* cl, storage* st):
		op(c, ident),
		_cluster(cl),
		_storage(st) {
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
int op_proxy_read::run_client(storage::entry& e) {
	if (this->_run_client(e) < 0) {
		return -1;
	}

	return this->_parse_client_parameter(e);
}

/**
 *	send client request
 */
int op_proxy_read::run_client(list<storage::entry>& e) {
	if (this->_run_client(e) < 0) {
		return -1;
	}

	return this->_parse_client_parameter(e);
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_proxy_read::_parse_server_parameter() {
	return 0;
}

int op_proxy_read::_run_server() {
	return 0;
}

int op_proxy_read::_run_client(storage::entry& e) {
	return 0;
}

int op_proxy_read::_run_client(list<storage::entry>& e) {
	return 0;
}

int op_proxy_read::_parse_client_parameter(storage::entry& e) {
	return 0;
}

int op_proxy_read::_parse_client_parameter(list<storage::entry>& e) {
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
