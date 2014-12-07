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
 *	client.cc
 *	
 *	implementation of gree::flare::client
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "client.h"

#include "connection_tcp.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for client
 */
client::client(string node_server_name, int node_server_port):
		_node_server_name(node_server_name),
		_node_server_port(node_server_port) {
	this->_connection = shared_connection(new connection_tcp(_node_server_name, _node_server_port));
}

/**
 *	dtor for client
 */
client::~client() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	connect to node
 */
int client::connect() {
	if (this->_connection->is_available()) {
		log_info("connection state is already available -> skip connecting", 0);
		return 0;
	}

	if (this->_connection->open() < 0) {
		return -1;
	}

	return 0;
}

/**
 *	disconnect from node
 */
int client::disconnect() {
	if (this->_connection->is_available()) {
		log_info("connection state is already unavailable -> skip disconnecting", 0);
		return 0;
	}

	if (this->_connection->close() < 0) {
		return -1;
	}

	return 0;
}

/**
 *	[op] get
 */
op::result client::get(string key, storage::entry& e) {
	e.key = key;
	
	op_get* p = new op_get(this->_connection, NULL, NULL);
	if (p->run_client(e, 0) < 0) {
		log_err("get operation failed", 0);
		delete p;
		return op::result_error;
	}

	delete p;

	return e.is_data_available() ? op::result_ok : op::result_not_found;
}

/**
 *	[op] gets
 */
op::result client::gets(string key, storage::entry& e) {
	e.key = key;
	
	op_gets* p = new op_gets(this->_connection, NULL, NULL);
	if (p->run_client(e, 0) < 0) {
		log_err("gets operation failed", 0);
		delete p;
		return op::result_error;
	}

	delete p;

	return e.is_data_available() ? op::result_ok : op::result_not_found;
}

/**
 *	[op] add
 */
op::result client::add(string key, const char* data, uint64_t data_size, int flag) {
	if (this->_connection->is_available() == false) {
		log_info("connection is not avalable -> trying to reconnect...", 0);
		if (this->_connection->open() < 0) {
			return op::result_error;
		}
	}

	op_add* p = new op_add(this->_connection, NULL, NULL);
	storage::entry e;
	e.key = key;
	e.flag = flag;
	e.size = data_size;
	e.data = shared_byte(new uint8_t[e.size]);
	memcpy(e.data.get(), data, e.size);

	if (p->run_client(e) < 0) {
		log_err("add operation failed", 0);
		delete p;
		return op::result_error;
	}

	op::result r = p->get_result();
	log_debug("add operation successfully done (code=%s, message=%s)", op::result_cast(r).c_str(), p->get_result_message().c_str());

	delete p;

	return r;
}

/**
 *	[op] add
 */
op::result client::add(string key, int data, int flag) {
	char buf[BUFSIZ];
	int data_size = snprintf(buf, sizeof(buf), "%d", data);

	return this->add(key, buf, data_size, flag);
}

/**
 *	[op] cas
 */
op::result client::cas(string key, const char* data, uint64_t data_size, int flag, uint64_t version) {
	if (this->_connection->is_available() == false) {
		log_info("connection is not avalable -> trying to reconnect...", 0);
		if (this->_connection->open() < 0) {
			return op::result_error;
		}
	}

	op_cas* p = new op_cas(this->_connection, NULL, NULL);
	storage::entry e;
	e.key = key;
	e.flag = flag;
	e.version = version;
	e.size = data_size;
	e.data = shared_byte(new uint8_t[e.size]);
	memcpy(e.data.get(), data, e.size);

	if (p->run_client(e) < 0) {
		log_err("cas operation failed", 0);
		delete p;
		return op::result_error;
	}

	op::result r = p->get_result();
	log_debug("cas operation successfully done (code=%s, message=%s)", op::result_cast(r).c_str(), p->get_result_message().c_str());

	delete p;

	return r;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
