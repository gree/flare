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
 *	handler_request.cc
 *	
 *	implementation of gree::flare::handler_request
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "handler_request.h"

#include "op_parser_binary_index.h"
#include "op_parser_text_index.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for handler_request
 */
handler_request::handler_request(shared_thread t, shared_connection_tcp c):
		thread_handler(t),
		_connection(c) {
}

/**
 *	dtor for handler_request
 */
handler_request::~handler_request() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	run thread proc
 */
int handler_request::run() {
	this->_thread->set_peer(this->_connection->get_host(), this->_connection->get_port());

	for (;;) {
		this->_thread->set_state("wait");
		this->_thread->set_op("");

		op* p = op_parser::parse_server<op_parser_binary_index, op_parser_text_index>(this->_connection);
		if (p == NULL) {
			this->_thread->set_state("shutdown");
			if (this->_thread->is_shutdown_request()) {
				log_info("thread shutdown request -> breaking loop", 0);
			} else {
				log_info("something is going wrong while parsing request -> breaking loop", 0);
			}
			break;
		}

		p->set_thread(this->_thread);
		this->_thread->set_state("accept");
		this->_thread->set_op(p->get_ident());

		p->run_server();

		if (p->is_shutdown_request()) {
			this->_thread->set_state("shutdown");
			log_info("session shutdown request -> breaking loop", 0);
			delete p;
			break;
		}

		delete p;

		if (this->_thread->is_shutdown_request()) {
			this->_thread->set_state("shutdown");
			log_info("thread shutdown request -> breaking loop", 0);
			break;
		}
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
