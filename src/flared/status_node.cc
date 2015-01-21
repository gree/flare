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
 *	status_node.cc
 *
 *	implementation of gree::flare::status_node
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#include "status_node.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for status_node
 */
status_node::status_node():
	status(),
	_node_status_code(node_status_ok) {
}

/**
 *	dtor for status_node
 */
status_node::~status_node() {
}
// }}}

// {{{ public methods
void status_node::set_node_status_code(node_status_code s) {
	this->_node_status_code = s;
	this->_status_code = this->_get_status_of(s);
}
// }}}

// {{{ protected methdos
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
