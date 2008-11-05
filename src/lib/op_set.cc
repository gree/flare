/**
 *	op_set.cc
 *
 *	implementation of gree::flare::op_set
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_set.h"
#include "queue_proxy_write.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_set
 */
op_set::op_set(shared_connection c, cluster* cl, storage* st):
		op(c, "set"),
		_cluster(cl),
		_storage(st) {
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
/**
 *	send client request
 */
int op_set::run_client(storage::entry& e) {
	if (this->_run_client(e) < 0) {
		return -1;
	}

	return this->_parse_client_parameter(e);
}
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

	char q[BUFSIZ];
	try {
		// key
		int n = util::next_word(p, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no key found", 0);
			throw -1;
		}
		this->_entry.key = q;
		log_debug("storing key [%s]", this->_entry.key.c_str());

		// flag
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no flag found", 0);
			throw -1;
		}
		try {
			this->_entry.flag = lexical_cast<uint32_t>(q);
			log_debug("storing flag [%u]", this->_entry.flag);
		} catch (bad_lexical_cast e) {
			log_debug("invalid flag (flag=%s)", q);
			throw -1;
		}
		
		// expire
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no expire found", 0);
			throw -1;
		}
		try {
			this->_entry.expire = lexical_cast<time_t>(q);
			log_debug("storing expire [%u]", this->_entry.expire);
		} catch (bad_lexical_cast e) {
			log_debug("invalid expire (expire=%s)", q);
			throw -1;
		}

		// size
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no size found", 0);
			throw -1;
		}
		try {
			this->_entry.size = lexical_cast<uint64_t>(q);
			log_debug("storing size [%u]", this->_entry.size);
		} catch (bad_lexical_cast e) {
			log_debug("invalid size (size=%s)", q);
			throw -1;
		}

		// version (if we have)
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0]) {
			try {
				this->_entry.version = lexical_cast<uint64_t>(q);
				log_debug("storing version [%u]", this->_entry.version);
			} catch (bad_lexical_cast e) {
				log_debug("invalid version (version=%s)", q);
				throw -1;
			}
		}

		// option
		n += util::next_word(p+n, q, sizeof(q));
		while (q[0]) {
			storage::option r = storage::option_none;
			if (storage::option_cast(q, r) < 0) {
				log_debug("unknown option [%s] (cast failed)", q);
				throw -1;
			}
			this->_entry.option |= r;
			log_debug("storing option [%s -> %d]", q, r);

			n += util::next_word(p+n, q, sizeof(q));
		}
	} catch (int e) {
		_delete_(p);
		return e;
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
	// pre-proxy (proxy if node is not master in request-partition)
	shared_queue_proxy_write q;
	cluster::proxy_request r_proxy = this->_cluster->pre_proxy_write(this, q);
	if (r_proxy == cluster::proxy_request_complete) {
		if (q->is_success() == false) {
			this->_send_result(result_server_error, "proxy error");
		} else {
			this->_send_result(q->get_result(), q->get_result_message().c_str());
		}
		return 0;
	} else if (r_proxy == cluster::proxy_request_error_enqueue) {
		return this->_send_result(result_server_error, "proxy failure");
	} else if (r_proxy == cluster::proxy_request_error_partition) {
		return this->_send_result(result_server_error, "no partition available");
	}

	// storage i/o
	storage::result r_storage;
	if (this->_storage->set(this->_entry, r_storage) < 0) {
		return this->_send_result(result_server_error, "i/o error");
	}
	
	// post-proxy (notify updates to slaves if we need)
	
	return this->_send_result(static_cast<result>(r_storage));
}

int op_set::_run_client(storage::entry& e) {
	int request_len = e.key.size() + e.size + BUFSIZ;
	char* request = _new_ char[request_len];
	int offset = snprintf(request, request_len, "set %s %u %ld %llu", e.key.c_str(), e.flag, e.expire, e.size);
	if (e.version > 0) {
		offset += snprintf(request+offset, request_len-offset, " %llu", e.version);
	}
	if (e.option & storage::option_noreply) {
		offset += snprintf(request+offset, request_len-offset, " %s", storage::option_cast(storage::option_noreply).c_str());
	}
	if (e.option & storage::option_sync) {
		offset += snprintf(request+offset, request_len-offset, " %s", storage::option_cast(storage::option_sync).c_str());
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
