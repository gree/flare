/**
 *	handler_monitor.cc
 *
 *	implementation of gree::flare::handler_monitor
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "handler_monitor.h"
#include "op_ping.h"
#include "queue_node_sync.h"
#include "queue_update_monitor_interval.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_monitor
 */
handler_monitor::handler_monitor(shared_thread t, cluster* cl, string node_server_name, int node_server_port):
		thread_handler(t),
		_cluster(cl),
		_node_server_name(node_server_name),
		_node_server_port(node_server_port),
		_monitor_interval(0) {
}

/**
 *	dtor for handler_monitor
 */
handler_monitor::~handler_monitor() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_monitor::run() {
	bool down = false;

	this->_thread->set_peer(this->_node_server_name, this->_node_server_port);
	this->_thread->set_state("connect");

	shared_connection c(new connection());
	this->_connection = c;
	if (c->open(this->_node_server_name, this->_node_server_port) < 0) {
		log_err("failed to connect to node server [name=%s, port=%d] -> dispatch node down event and continue monitoring", this->_node_server_name.c_str(), this->_node_server_port);
		this->_cluster->down_node(this->_node_server_name, this->_node_server_port);
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
		int r = this->_thread->dequeue(q, this->_monitor_interval);
		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0); 
			this->_thread->set_state("shutdown");
			break;
		}

		if (r == ETIMEDOUT) {
			log_debug("dequeue timed out -> sending ping to node server (%s:%d)", this->_node_server_name.c_str(), this->_node_server_port);
			if (this->_process_monitor() < 0) {
				if (down == false) {
					this->_cluster->down_node(this->_node_server_name, this->_node_server_port);
				}
				down = true;
			} else if (down) {
				down = false;
				this->_cluster->up_node(this->_node_server_name, this->_node_server_port);
			}
		} else {
			this->_process_queue(q);
			q->sync_unref();
		}
	}

	return 0;
}
// }}}

// {{{ protected methods
int handler_monitor::_process_monitor() {
	if (this->_connection->is_available() == false) {
		log_info("connection for %s:%d is unavailable -> re-opening...", this->_node_server_name.c_str(), this->_node_server_port);
		if (this->_connection->open(this->_node_server_name, this->_node_server_port) < 0) {
			return -1;
		}
	}

	op_ping* p = _new_ op_ping(this->_connection);
	this->_thread->set_state("execute");
	this->_thread->set_op(p->get_ident());

	if (p->run_client() < 0) {
		_delete_(p);
		return -1;
	}

	_delete_(p);
	return 0;
}

int handler_monitor::_process_queue(shared_thread_queue q) {
	log_debug("queue: %s", q->get_ident().c_str());
	this->_thread->set_state("execute");
	this->_thread->set_op(q->get_ident());

	if (q->get_ident() == "update_monitor_interval") {
		shared_queue_update_monitor_interval r = shared_dynamic_cast<queue_update_monitor_interval, thread_queue>(q);
		log_debug("updating monitor interval [%d -> %d]", this->_monitor_interval, r->get_monitor_interval());
		this->_monitor_interval = r->get_monitor_interval();
	} else if (q->get_ident() == "node_sync") {
		shared_queue_node_sync r = shared_dynamic_cast<queue_node_sync, thread_queue>(q);
		return r->run(this->_connection);
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
