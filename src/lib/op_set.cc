/**
 *	op_set.cc
 *
 *	implementation of gree::flare::op_set
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "op_set.h"
#include "queue_proxy_write.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_set
 */
op_set::op_set(shared_connection c, cluster* cl, storage* st):
		op_proxy_write(c, "set", cl, st) {
	this->_behavior = 0;
}

/**
 *	ctor for op_set
 */
op_set::op_set(shared_connection c, string ident, cluster* cl, storage* st):
		op_proxy_write(c, ident, cl, st) {
	this->_behavior = 0;
}

/**
 *	dtor for op_set
 */
op_set::~op_set() {
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
int op_set::_parse_server_parameter() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	if (this->_entry.parse(p, this->get_ident() == "cas" ? storage::parse_type_cas : storage::parse_type_set) < 0) {
		_delete_(p);
		return -1;
	}
	_delete_(p);

	// data (+2 -> "\r\n")
	if (this->_connection->readsize(this->_entry.size + 2, &p) < 0) {
		return -1;
	}
	shared_byte data(new uint8_t[this->_entry.size]);
	memcpy(data.get(), p, this->_entry.size);
	_delete_(p);
	this->_entry.data = data;
	log_debug("storing data [%d bytes]", this->_entry.size);

	return 0;
}

int op_set::_run_server() {
	stats_object->increment_cmd_set();

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
	if (this->_storage->set(this->_entry, r_storage, this->_behavior) < 0) {
		return this->_send_result(result_server_error, "i/o error");
	}
	if (r_storage == storage::result_stored) {
		stats_object->increment_total_items();
		// post-proxy (notify updates to slaves if we need)
		r_proxy = this->_cluster->post_proxy_write(this, this->_is_sync(this->_entry.option, this->_cluster->get_replication_type()));
	}
	
	if ((this->_entry.option & storage::option_noreply) == 0) {
		return this->_send_result(static_cast<result>(r_storage));
	}

	return 0;
}

int op_set::_run_client(storage::entry& e) {
	string proxy_ident = this->_get_proxy_ident();
	int request_len = proxy_ident.size() + e.key.size() + e.size + BUFSIZ;
	char* request = _new_ char[request_len];
	int offset = snprintf(request, request_len, "%s%s %s %u %ld %llu", proxy_ident.c_str(), this->get_ident().c_str(), e.key.c_str(), e.flag, e.expire, static_cast<unsigned long long>(e.size));
	if (e.version > 0 || this->get_ident() == "cas") {
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
	memcpy(request+offset, e.data.get(), e.size);
	offset += e.size;
	offset += snprintf(request+offset, request_len-offset, line_delimiter);
	if (this->_connection->write(request, offset) < 0) {
		_delete_(request);
		return -1;
	}
	_delete_(request);

	return 0;
}

int op_set::_parse_client_parameter(storage::entry& e) {
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
