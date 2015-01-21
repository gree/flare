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
 *	queue_node_state.cc
 *
 *	implementation of gree::flare::queue_node_state
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#include "queue_node_state.h"
#include "op_node_sync.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_node_state
 */
queue_node_state::queue_node_state(string node_server_name, int node_server_port, state_operation operation):
		thread_queue("node_state"),
		_node_server_name(node_server_name),
		_node_server_port(node_server_port),
		_operation(operation) {
}

/**
 *	dtor for queue_node_state
 */
queue_node_state::~queue_node_state() {
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
