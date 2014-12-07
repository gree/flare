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
 *	op_append.cc
 *
 *	implementation of gree::flare::op_append
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_append.h"
#include "binary_request_header.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_append
 */
op_append::op_append(shared_connection c, cluster* cl, storage* st):
		op_set(c, "append", binary_header::opcode_append, cl, st) {
	this->_behavior = storage::behavior_replace | storage::behavior_append;
}

/**
 *	ctor for op_append
 */
op_append::op_append(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_set(c, ident, opcode, cl, st) {
	this->_behavior = storage::behavior_replace | storage::behavior_append;
}

/**
 *	dtor for op_append
 */
op_append::~op_append() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_append::_parse_binary_request(const binary_request_header& header, const char* body) {
	if (header.get_extras_length() == _binary_request_required_extras_length
			&& this->_entry.parse(header, body) == 0) {
		shared_byte data(new uint8_t[this->_entry.size]);
		memcpy(data.get(), body + header.get_extras_length() + header.get_key_length(), this->_entry.size);
		this->_entry.data = data;
		return 0;
	}
	return -1;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
