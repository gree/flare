/**
 *	queue_forward_query.cc
 *
 *	implementation of gree::flare::queue_forward_query
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#include "queue_forward_query.h"
#include "connection_tcp.h"
#include "op_set.h"
#include "op_delete.h"
#include "op_proxy_write.h"
#include "op_touch.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_forward_query
 */
queue_forward_query::queue_forward_query(storage::entry entry, string op_ident):
		thread_queue(op_ident),
		_entry(entry),
		_op_ident(op_ident),
		_result(op::result_none),
		_result_message("") {
}

/**
 *	dtor for queue_forward_query
 */
queue_forward_query::~queue_forward_query() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int queue_forward_query::run(shared_connection c) {
#ifdef DEBUG
	if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
		log_debug("forwarding query (host=%s, port=%d, op=%s, key=%s, version=%u)", ctp->get_host().c_str(), ctp->get_port(), this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
	}
#endif

	op_proxy_write* p = this->_get_op(this->_op_ident, c);
	if (p == NULL) {
		return -1;
	}

	int retry = queue_forward_query::max_retry;
	while (retry > 0) {
			if (p->run_client(this->_entry) < 0) {
				break;
			}
			if (c->is_available() == false) {
#ifdef DEBUG
				if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
					log_debug("reconnecting (host%s, port%d)", ctp->get_host().c_str(), ctp->get_port());
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
	delete p;

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
op_proxy_write* queue_forward_query::_get_op(string op_ident, shared_connection c) {
	if (op_ident == "set"
			|| op_ident == "add"
			|| op_ident == "replace"
			|| op_ident == "cas"
			|| op_ident == "append"
			|| op_ident == "prepend"
			|| op_ident == "incr"
			|| op_ident == "decr") {
		return new op_set(c, NULL, NULL);
	} else if (op_ident == "delete") {
		return new op_delete(c, NULL, NULL);
	} else if (op_ident == "touch" || op_ident == "gat") {
		return new op_touch(c, NULL, NULL);
	}
	log_warning("unknown op (ident=%s)", op_ident.c_str());

	return NULL;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
