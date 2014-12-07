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
 *	queue_proxy_read.cc
 *
 *	implementation of gree::flare::queue_proxy_read
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "queue_proxy_read.h"
#include "connection_tcp.h"
#include "op_proxy_read.h"
#include "op_get.h"
#include "op_gets.h"
#include "op_keys.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_proxy_read
 */
queue_proxy_read::queue_proxy_read(cluster* cl, storage* st, vector<string> proxy, storage::entry entry, void* parameter, string op_ident):
		thread_queue("proxy_read"),
		_cluster(cl),
		_storage(st),
		_proxy(proxy),
		_entry(entry),
		_parameter(parameter),
		_op_ident(op_ident),
		_result(op::result_none),
		_result_message("") {
}

/**
 *	dtor for queue_proxy_read
 */
queue_proxy_read::~queue_proxy_read() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int queue_proxy_read::run(shared_connection c) {
#ifdef DEBUG
	if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
		log_debug("proxy request (read) (host=%s, port=%d, op=%s, key=%s, version=%u)", ctp->get_host().c_str(), ctp->get_port(), this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
	}
#endif

	op_proxy_read* p = this->_get_op(this->_op_ident, c);
	if (p == NULL) {
		return -1;
	}
	p->set_proxy(this->_proxy);

	int retry = queue_proxy_read::max_retry;
	if (p->is_multiple_response()) {
		this->_entry_list.push_back(this->_entry);
	}
	while (retry > 0) {
		if (p->is_multiple_response()) {
			if (p->run_client(this->_entry_list, this->_parameter) >= 0) {
				break;
			}
		} else {
			if (p->run_client(this->_entry, this->_parameter) >= 0) {
				break;
			}
		}
		if (c->is_available() == false) {
#ifdef DEBUG
			if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
				log_debug("reconnecting (host=%s, port=%d)", ctp->get_host().c_str(), ctp->get_port());
			}
#endif
			c->open();
		}
		retry--;
	}
	if (retry <= 0) {
		delete p;
		return -1;
	}

	this->_success = true;
	this->_result = p->get_result();
	this->_result_message = p->get_result_message();
	delete p;

	return 0;
}
// }}}

// {{{ protected methods
op_proxy_read* queue_proxy_read::_get_op(string op_ident, shared_connection c) {
	if (op_ident == "get") {
		return new op_get(c, this->_cluster, this->_storage);
	} else if (op_ident == "gets") {
		return new op_gets(c, this->_cluster, this->_storage);
	} else if (op_ident == "keys") {
		return new op_keys(c, this->_cluster, this->_storage);
	}
	log_warning("unknown op (ident=%s)", op_ident.c_str());

	return NULL;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
