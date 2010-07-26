/**
 *	op_delete.cc
 *
 *	implementation of gree::flare::op_delete
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_delete.h"
#include "queue_proxy_write.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_delete
 */
op_delete::op_delete(shared_connection c, cluster* cl, storage* st):
		op_proxy_write(c, "delete", cl, st) {
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
int op_delete::_parse_server_parameter() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	if (this->_entry.parse(p, storage::parse_type_delete) < 0) {
		_delete_(p);
		return -1;
	}
	_delete_(p);

	return 0;
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
	if (this->_storage->remove(this->_entry, r_storage) < 0) {
		return this->_send_result(result_server_error, "i/o error");
	}
	
	// post-proxy (notify updates to slaves if we need)
	if (r_storage == storage::result_deleted) {
		r_proxy = this->_cluster->post_proxy_write(this, this->_is_sync(this->_entry.option, this->_cluster->get_replication_type()));
	}
	
	if ((this->_entry.option & storage::option_noreply) == 0) {
		return this->_send_result(static_cast<result>(r_storage));
	}

	return 0;
}

int op_delete::_run_client(storage::entry& e) {
	string proxy_ident = this->_get_proxy_ident();
	int request_len = proxy_ident.size() + e.key.size() + e.size + BUFSIZ;
	char* request = _new_ char[request_len];
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
	offset += snprintf(request+offset, request_len-offset, line_delimiter);
	if (this->_connection->write(request, offset) < 0) {
		_delete_(request);
		return -1;
	}
	_delete_(request);

	return 0;
}

int op_delete::_parse_client_parameter(storage::entry& e) {
	if (e.option & storage::option_noreply) {
		this->_result = result_none;
		return 0;
	}

	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	if (this->_parse_response(p, this->_result, this->_result_message) < 0) {
		_delete_(p);
		return -1;
	}
	_delete_(p);

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
