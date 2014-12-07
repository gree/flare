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
 *	op_add.cc
 *
 *	implementation of gree::flare::op_add
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_add.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_add
 */
op_add::op_add(shared_connection c, cluster* cl, storage* st):
		op_set(c, "add", binary_header::opcode_add, cl, st) {
	this->_behavior = storage::behavior_add;
}

/**
 *	ctor for op_add
 */
op_add::op_add(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_set(c, ident, opcode, cl, st) {
	this->_behavior = storage::behavior_add;
}

/**
 *	dtor for op_add
 */
op_add::~op_add() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
