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
 *	op_quit.cc
 *
 *	implementation of gree::flare::op_quit
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_quit.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_quit
 */
op_quit::op_quit(shared_connection c):
		op(c, "quit", binary_header::opcode_quit) {
}

/**
 *	ctor for op_quit
 */
op_quit::op_quit(shared_connection c, string ident, binary_header::opcode opcode):
		op(c, ident, opcode) {
}

/**
 *	dtor for op_quit
 */
op_quit::~op_quit() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_quit::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[1024];
	util::next_word(p, q, sizeof(q));
	if (q[0]) {
		// no arguments allowed
		log_debug("bogus string(s) found [%s] -> error", q); 
		delete[] p;
		return -1;
	}

	delete[] p;

	return 0;
}

int op_quit::_run_server() {
	log_info("requesting shutdown", 0);
	this->_shutdown_request = true;
	_send_result(result_end);
	
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
