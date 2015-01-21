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
 *	stats_node.cc
 *	
 *	implementation of gree::flare::stats_node
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flared.h"
#include "stats_node.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for stats_node
 */
stats_node::stats_node():
		stats::stats() {
}

/**
 *	dtor for stats_node
 */
stats_node::~stats_node() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
uint32_t stats_node::get_curr_connections(thread_pool* tp) {
	return tp->get_thread_size(thread_pool::thread_type_request);
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
