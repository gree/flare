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
