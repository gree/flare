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
 *	handler_alarm.cc
 *	
 *	implementation of gree::flare::handler_alarm
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "handler_alarm.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for handler_alarm
 */
handler_alarm::handler_alarm(shared_thread t):
		thread_handler(t) {
}

/**
 *	dtor for handler_alarm
 */
handler_alarm::~handler_alarm() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	run thread proc
 */
int handler_alarm::run() {
	this->_thread->set_state("wait"); 
	this->_thread->set_op("");

	for (;;) {
		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			break;
		}

		stats_object->update_timestamp();

		sleep(1);
	}

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
