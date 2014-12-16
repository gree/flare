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
 *	op_delete.cc
 *
 *	implementation of gree::flare::op_delete
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "op_delete.h"
#include "queue_proxy_write.h"
#include "binary_request_header.h"
#include "time_watcher_scoped_observer.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_delete
 */
op_delete::op_delete(shared_connection c, cluster* cl, storage* st):
		op_proxy_write(c, "delete", binary_header::opcode_delete, cl, st) {
}

/**
 *	ctor for op_delete
 */
op_delete::op_delete(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_proxy_write(c, ident, opcode, cl, st) {
}

/**
 *	dtor for op_delete
 */
op_delete::~op_delete() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_delete::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	if (this->_entry.parse(p, storage::parse_type_delete) < 0) {
		delete[] p;
		return -1;
	}
	delete[] p;

	return 0;
}

int op_delete::_parse_binary_request(const binary_request_header& header, const char* body) {
	if (body
			&& !header.get_extras_length()
			&& this->_entry.parse(header, body) == 0) {
		return 0;
	}
	return -1;
}

int op_delete::_run_server() {
	// pre-proxy (proxy if node is not master in request-partition)
	shared_queue_proxy_write q;
	cluster::proxy_request r_proxy = this->_cluster->pre_proxy_write(this, q);
	if (r_proxy == cluster::proxy_request_complete) {
		if (this->_entry.option & storage::option_noreply) {
			// we should not access variable "q"
			return 0;
		} else if (q->is_success() == false) {
			return this->_send_result(result_server_error, "proxy error");
		} else {
			return this->_send_result(q->get_result(), q->get_result_message().c_str());
		}
	} else if (r_proxy == cluster::proxy_request_error_enqueue) {
		return this->_send_result(result_server_error, "proxy failure");
	} else if (r_proxy == cluster::proxy_request_error_partition) {
		return this->_send_result(result_server_error, "no partition available");
	}

	// storage i/o
	storage::result r_storage;
	int retcode;
	{
		storage_access_info info = { this->_thread };
		time_watcher_scoped_observer ob(info);
		retcode = this->_storage->remove(this->_entry, r_storage);
	}
	if (retcode < 0) {
		return this->_send_result(result_server_error, "i/o error");
	}

	stats_object->increment_write_query_without_proxy();

	if (r_storage == storage::result_deleted) {
		stats_object->increment_delete_hits();
		// post-proxy (notify updates to slaves if we need)
		r_proxy = this->_cluster->post_proxy_write(this,
																							 this->_is_sync(this->_entry.option,
																															this->_cluster->get_replication_type()
																															));
	} else if (r_storage == storage::result_not_found) {
		stats_object->increment_delete_misses();
	}
	
	if ((this->_entry.option & storage::option_noreply) == 0) {
		return this->_send_result(static_cast<result>(r_storage));
	}

	return 0;
}

int op_delete::_run_client(storage::entry& e) {
	string proxy_ident = this->_get_proxy_ident();
	int request_len = proxy_ident.size() + e.key.size() + e.size + BUFSIZ;
	char* request = new char[request_len];
	int offset = snprintf(request, request_len, "%sdelete %s %ld", proxy_ident.c_str(), e.key.c_str(), e.expire);
	if (e.version > 0) {
		offset += snprintf(request+offset, request_len-offset, " %llu", static_cast<unsigned long long>(e.version));
	}
	if (e.option & storage::option_noreply) {
		offset += snprintf(request+offset, request_len-offset, " %s", storage::option_cast(storage::option_noreply).c_str());
	}
	if (e.option & storage::option_sync) {
		offset += snprintf(request+offset, request_len-offset, " %s", storage::option_cast(storage::option_sync).c_str());
	}
	if (e.option & storage::option_async) {
		offset += snprintf(request+offset, request_len-offset, " %s", storage::option_cast(storage::option_async).c_str());
	}
	offset += snprintf(request+offset, request_len-offset, "%s", line_delimiter);
	if (this->_connection->write(request, offset) < 0) {
		delete[] request;
		return -1;
	}
	delete[] request;

	return 0;
}

int op_delete::_parse_text_client_parameters(storage::entry& e) {
	if (e.option & storage::option_noreply) {
		this->_result = result_none;
		return 0;
	}

	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	if (this->_parse_text_response(p, this->_result, this->_result_message) < 0) {
		delete[] p;
		return -1;
	}
	delete[] p;

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
