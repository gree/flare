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
 *	op_getk.cc
 *
 *	implementation of gree::flare::op_getk
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 *	$Id$
 */
#include "op_getk.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_getk
 */
op_getk::op_getk(shared_connection c, cluster* cl, storage* st):
		op_get(c, "get", binary_header::opcode_getk, cl, st) {
}

/**
 *	ctor for op_getk
 */
op_getk::op_getk(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_get(c, ident, opcode, cl, st) {
}

/**
 *	dtor for op_getk
 */
op_getk::~op_getk() {
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
