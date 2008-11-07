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
#include "op_set.h"

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
		_result_message("") {
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
	this->_result_message = p->get_result_message();
	_delete_(p);

	return 0;
}
// }}}

// {{{ protected methods
op_proxy_write* queue_proxy_write::_get_op(string op_ident, shared_connection c) {
	if (op_ident == "set") {
		return _new_ op_set(c, this->_cluster, this->_storage);
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
