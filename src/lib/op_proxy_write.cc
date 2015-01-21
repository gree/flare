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
op_proxy_write::op_proxy_write(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op(c, ident, opcode),
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

	return this->_parse_text_client_parameters(e);
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_proxy_write::_parse_text_server_parameters() {
	return 0;
}

int op_proxy_write::_run_server() {
	return 0;
}

int op_proxy_write::_run_client(storage::entry& e) {
	return 0;
}

int op_proxy_write::_parse_text_client_parameters(storage::entry& e) {
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
