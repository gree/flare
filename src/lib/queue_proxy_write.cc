/**
 *	queue_proxy_write.cc
 *
 *	implementation of gree::flare::queue_proxy_write
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "queue_proxy_write.h"
#include "op_proxy_write.h"
#include "op_add.h"
#include "op_append.h"
#include "op_cas.h"
#include "op_decr.h"
#include "op_delete.h"
#include "op_incr.h"
#include "op_prepend.h"
#include "op_set.h"
#include "op_replace.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_proxy_write
 */
queue_proxy_write::queue_proxy_write(cluster* cl, storage* st, vector<string> proxy, storage::entry entry, string op_ident):
		thread_queue("proxy_write"),
		_cluster(cl),
		_storage(st),
		_proxy(proxy),
		_entry(entry),
		_op_ident(op_ident),
		_result(op::result_none),
		_result_message(""),
		_post_proxy(false),
		_generic_value(0) {
}

/**
 *	dtor for queue_proxy_write
 */
queue_proxy_write::~queue_proxy_write() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int queue_proxy_write::run(shared_connection c) {
	log_debug("proxy request (write) (host=%s, port=%d, op=%s, key=%s, version=%u)", c->get_host().c_str(), c->get_port(), this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);

	op_proxy_write* p = this->_get_op(this->_op_ident, c);
	if (p == NULL) {
		return -1;
	}
	p->set_proxy(this->_proxy);

	int retry = queue_proxy_write::max_retry;
	while (retry > 0) {
		if (p->run_client(this->_entry) >= 0) {
			break;
		}
		if (c->is_available() == false) {
			log_debug("reconnecting (host=%s, port=%d)", c->get_host().c_str(), c->get_port());
			c->open();
		}
		retry--;
	}
	if (retry <= 0) {
		_delete_(p);
		return -1;
	}

	this->_success = true;
	this->_result = p->get_result();
	// :(
	log_debug("result: %s:%d", p->get_ident().c_str(), this->_result);
	if ((p->get_ident() == "incr" || p->get_ident() == "decr") && this->_result == op::result_stored) {
		log_debug("available: %d", this->_entry.is_data_available());
		if (this->_entry.is_data_available()) {
			char buf[BUFSIZ];
			memcpy(buf, this->_entry.data.get(), this->_entry.size);
			snprintf(buf+this->_entry.size, sizeof(buf)-this->_entry.size, "%s", line_delimiter);
			this->_result_message = buf;
		} else {
			this->_result_message = p->get_result_message();
		}
	} else {
		this->_result_message = p->get_result_message();
	}
	_delete_(p);

	return 0;
}
// }}}

// {{{ protected methods
op_proxy_write* queue_proxy_write::_get_op(string op_ident, shared_connection c) {
	if (op_ident == "set") {
		return _new_ op_set(c, this->_cluster, this->_storage);
	} else if (op_ident == "add") {
		if (this->is_post_proxy()) {
			return _new_ op_set(c, this->_cluster, this->_storage);
		} else {
			return _new_ op_add(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "replace") {
		if (this->is_post_proxy()) {
			return _new_ op_set(c, this->_cluster, this->_storage);
		} else {
			return _new_ op_replace(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "cas") {
		if (this->is_post_proxy()) {
			return _new_ op_set(c, this->_cluster, this->_storage);
		} else {
			return _new_ op_cas(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "append") {
		if (this->is_post_proxy()) {
			return _new_ op_set(c, this->_cluster, this->_storage);
		} else {
			return _new_ op_append(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "prepend") {
		if (this->is_post_proxy()) {
			return _new_ op_set(c, this->_cluster, this->_storage);
		} else {
			return _new_ op_prepend(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "incr") {
		if (this->is_post_proxy()) {
			return _new_ op_set(c, this->_cluster, this->_storage);
		} else {
			op_incr* p = _new_ op_incr(c, this->_cluster, this->_storage);
			p->set_value(this->_generic_value);
			return p;
		}
	} else if (op_ident == "decr") {
		if (this->is_post_proxy()) {
			return _new_ op_set(c, this->_cluster, this->_storage);
		} else {
			op_incr* p = _new_ op_decr(c, this->_cluster, this->_storage);
			p->set_value(this->_generic_value);
			return p;
		}
	} else if (op_ident == "delete") {
		return _new_ op_delete(c, this->_cluster, this->_storage);
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
