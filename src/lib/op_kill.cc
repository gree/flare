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
 *	op_kill.cc
 *
 *	implementation of gree::flare::op_kill
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_kill.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_kill
 */
  op_kill::op_kill(shared_connection c, thread_pool* req_tp, thread_pool* other_tp):
		op(c, "kill"),
		_req_thread_pool(req_tp),
		_other_thread_pool(other_tp),
		_id(0) {
}

/**
 *	dtor for op_kill
 */
op_kill::~op_kill() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_kill::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[1024];
	try {
		int n = util::next_digit(p, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no thread id found", 0);
			throw -1;
		}

		try {
			this->_id = boost::lexical_cast<unsigned int>(q);
			log_debug("storing id [%u]", this->_id);
		} catch (boost::bad_lexical_cast e) {
			log_debug("invalid thread id (id=%s)", q);
			throw -1;
		}

		// no extra parameter allowed
		util::next_word(p+n, q, sizeof(q));
		if (q[0]) {
			log_debug("bogus string(s) found [%s] -> error", q);
			throw -1;
		}
	} catch (int e) {
		delete[] p;
		return e;
	}

	delete[] p;

	return 0;
}

int op_kill::_run_server() {
	log_info("killing thread (id=%u)", this->_id);

	shared_thread t;
	if (this->_req_thread_pool->get_active(this->_id, t) < 0 &&
			this->_other_thread_pool->get_active(this->_id, t) < 0
			) {
		log_debug("specified thread (id=%u) not found", this->_id);
		this->_send_result(result_client_error, "thread not found");
		return -1;
	}

	t->set_state("killed");
	t->shutdown(true, true);

	return this->_send_result(result_ok);
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
