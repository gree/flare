/**
 *	handler_proxy.cc
 *
 *	implementation of gree::flare::handler_proxy
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "handler_proxy.h"
#include "connection_tcp.h"
#include "queue_proxy_read.h"
#include "queue_proxy_write.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_proxy
 */
handler_proxy::handler_proxy(shared_thread t, cluster* cl, string node_server_name, int node_server_port):
		thread_handler(t),
		_cluster(cl),
		_node_server_name(node_server_name),
		_node_server_port(node_server_port),
		_noreply_count(0),
		_skip_proxy(false) {
}

/**
 *	dtor for handler_proxy
 */
handler_proxy::~handler_proxy() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_proxy::run() {
	this->_thread->set_peer(this->_node_server_name, this->_node_server_port);
	this->_thread->set_state("connect");

	shared_connection c(new connection_tcp(this->_node_server_name, this->_node_server_port));
	this->_connection = c;
	if (c->open() < 0) {
		log_err("failed to connect to node server [name=%s, port=%d]", this->_node_server_name.c_str(), this->_node_server_port);
	}

	for (;;) {
		this->_thread->set_state("wait");
		this->_thread->set_op("");

		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0); 
			this->_thread->set_state("shutdown");
			break;
		}

		// dequeue
		shared_thread_queue q;
		if (this->_thread->dequeue(q, 0) < 0) {
			// FIXME: check if we can safely ignore this...
			log_info("dequeued but no queue is available (something is inconsistent?)", 0);
			continue;
		}
		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0); 
			this->_thread->set_state("shutdown");
			break;
		}

		cluster::node n = this->_cluster->get_node(this->_node_server_name, this->_node_server_port);
		if (n.node_role == cluster::role_proxy) {
			if (!this->_skip_proxy) {
				log_warning("skip to proxy because the destination node is proxy [name=%s, port=%d]",
						this->_node_server_name.c_str(), this->_node_server_port);
				this->_skip_proxy = true;
			}
			string key = "";
			if (q->get_ident() == "proxy_read") {
				shared_queue_proxy_read r = dynamic_pointer_cast<queue_proxy_read, thread_queue>(q);
				if (r) {
					key = r->get_entry().key;
				}
			} else if (q->get_ident() == "proxy_write") {
				shared_queue_proxy_write r = dynamic_pointer_cast<queue_proxy_write, thread_queue>(q);
				if (r) {
					key = r->get_entry().key;
				}
			}
			log_notice("skipped proxy request is [ident=%s, key=%s]", q->get_ident().c_str(), key.c_str());
		} else {
			this->_process_queue(q);
			if (this->_skip_proxy) {
				log_notice("node [name=%s, port=%d] is rollback to active, stopped to skip to proxy",
						this->_node_server_name.c_str(), this->_node_server_port);
				this->_skip_proxy = false;
			}
		}

		// failover if we need

		q->sync_unref();
	}

	return 0;
}
// }}}

// {{{ protected methods
int handler_proxy::_process_queue(shared_thread_queue q) {
	log_debug("queue: %s", q->get_ident().c_str());
	this->_thread->set_state("execute");
	this->_thread->set_op(q->get_ident());

	if (q->get_ident() == "proxy_read") {
		shared_queue_proxy_read r = dynamic_pointer_cast<queue_proxy_read, thread_queue>(q);
		return r->run(this->_connection);
	} else if (q->get_ident() == "proxy_write") {
		shared_queue_proxy_write r = dynamic_pointer_cast<queue_proxy_write, thread_queue>(q);
		int noreply_window_limit = this->_cluster->get_noreply_window_limit();
		if (!r->is_post_proxy() || (r->get_entry().option & storage::option_noreply) || noreply_window_limit <= 0) {
			return r->run(this->_connection);
		} else {
			if (this->_noreply_count < noreply_window_limit) {
				this->_noreply_count++;
				storage::entry& entry = r->get_entry();
				uint32_t option = entry.option;
				entry.option = option | storage::option_noreply;
				r->run(this->_connection);
			} else {
				this->_noreply_count = 0;
				if (r->run(this->_connection) < 0) {
					log_err("failed to send '%s' command to %s:%d after noreply requests.",
									r->get_op_ident().c_str(), this->_node_server_name.c_str(), this->_node_server_port);
					return -1;
				}
			}
		}
	} else {
		log_warning("unknown queue [ident=%s] -> skip processing", q->get_ident().c_str());
		return -1;
	}

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
