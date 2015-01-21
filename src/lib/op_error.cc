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
 *	op_error.cc
 *
 *	implementation of gree::flare::op_error
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_error.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_error
 */
op_error::op_error(shared_connection c):
		op(c, "error") {
}

/**
 *	dtor for op_error
 */
op_error::~op_error() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_error::_parse_text_server_parameters() {
	// consume 1 line anyway...
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	delete[] p;

	return 0;
}

int op_error::_run_server() {
	this->_send_result(result_error);

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
