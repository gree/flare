/**
 *	op_parser_binary.cc
 *
 *	implementation of gree::flare::op_parser_binary
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_parser_binary.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_parser_binary
 */
op_parser_binary::op_parser_binary(shared_connection c):
		op_parser(c) {
}

/**
 *	dtor for op_parser_binary
 */
op_parser_binary::~op_parser_binary() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
op* op_parser_binary::parse_server() {
	op* r = NULL;
	try {
		const binary_request_header header(this->_connection);
		r = _determine_op(header);
		if (r)
			r->set_protocol(op::binary);
		header.push_back(this->_connection);
	} catch (...) {
		r = NULL;
	}
	return r;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
