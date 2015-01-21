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
 *	queue_update_monitor_option.cc
 *
 *	implementation of gree::flare::queue_update_monitor_option
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "queue_update_monitor_option.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_update_monitor_option
 */
queue_update_monitor_option::queue_update_monitor_option(int monitor_threshold, int monitor_interval, int monitor_read_timeout):
		thread_queue("update_monitor_option"),
		_monitor_threshold(monitor_threshold),
		_monitor_interval(monitor_interval),
		_monitor_read_timeout(monitor_read_timeout) {
}

/**
 *	dtor for queue_update_monitor_option
 */
queue_update_monitor_option::~queue_update_monitor_option() {
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
