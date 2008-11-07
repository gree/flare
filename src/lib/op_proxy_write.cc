/**
 *	op_proxy_write.cc
 *
 *	implementation of gree::flare::op_proxy_write
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_proxy_write.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_proxy_write
 */
op_proxy_write::op_proxy_write(shared_connection c, string ident, cluster* cl, storage* st):
		op(c, ident),
		_cluster(cl),
		_storage(st) {
}

/**
 *	dtor for op_proxy_write
 */
op_proxy_write::~op_proxy_write() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_proxy_write::run_client(storage::entry& e) {
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
int op_proxy_write::_parse_server_parameter() {
	return 0;
}

int op_proxy_write::_run_server() {
	return 0;
}

int op_proxy_write::_run_client(storage::entry& e) {
	return 0;
}

int op_proxy_write::_parse_client_parameter(storage::entry& e) {
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
