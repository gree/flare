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
#include "queue_update_monitor_option.h"

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
		_monitor_threshold(0),
		_monitor_interval(0),
		_monitor_read_timeout(0),
		_down_state(0) {
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
	this->_thread->set_peer(this->_node_server_name, this->_node_server_port);
	this->_thread->set_state("connect");

	shared_connection_tcp c(new connection_tcp(this->_node_server_name, this->_node_server_port));
	this->_connection = c;
	this->_connection->set_connect_retry_limit(0);

	if (c->open() < 0) {
		log_err("failed to connect to node server [name=%s, port=%d]", this->_node_server_name.c_str(), this->_node_server_port);
		this->_down();
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

		// sync w/ node_map for safe
		cluster::node n = this->_cluster->get_node(this->_node_server_name, this->_node_server_port);
		if (n.node_server_name == this->_node_server_name) {
			if (n.node_state == cluster::state_down) {
				this->_down_state = this->_monitor_threshold;
			} else if (this->_down_state >= this->_monitor_threshold) {
				this->_down_state = 0;
			}
		} else {
			log_warning("failed to get node information of %s", n.node_server_name.c_str()); 
		}

		if (r == ETIMEDOUT) {
			log_debug("dequeue timed out -> sending ping to node server (%s:%d)", this->_node_server_name.c_str(), this->_node_server_port);
			if (this->_process_monitor() < 0) {
				this->_down();
			} else {
				this->_up();
			}
		} else {
			int r = this->_process_queue(q);
			q->sync_unref();
			if (r < 0) {
				this->_down();
			}
		}
	}

	return 0;
}
// }}}

// {{{ protected methods
int handler_monitor::_process_monitor() {
	if (this->_connection->is_available() == false) {
		log_info("connection for %s:%d is unavailable -> re-opening...", this->_node_server_name.c_str(), this->_node_server_port);
		if (this->_connection->open() < 0) {
			return -1;
		}
	}

	int current_read_timeout = this->_connection->get_read_timeout();

	// clear read buf
	char* tmp;
	bool actual;
	this->_connection->set_read_timeout(0);
	if (this->_connection->read(&tmp, -1, false, actual) > 0) {
		delete[] tmp;
	}
	this->_connection->set_read_timeout(this->_monitor_read_timeout);

	op_ping* p = new op_ping(this->_connection);
	this->_thread->set_state("execute");
	this->_thread->set_op(p->get_ident());

	if (p->run_client() < 0) {
		this->_connection->set_read_timeout(current_read_timeout);
		delete p;
		return -1;
	}

	this->_connection->set_read_timeout(current_read_timeout);
	delete p;
	return 0;
}

int handler_monitor::_process_queue(shared_thread_queue q) {
	log_debug("queue: %s", q->get_ident().c_str());
	this->_thread->set_state("execute");
	this->_thread->set_op(q->get_ident());

	if (q->get_ident() == "update_monitor_option") {
		shared_queue_update_monitor_option r = boost::dynamic_pointer_cast<queue_update_monitor_option, thread_queue>(q);
		log_debug("updating monitor option [threshold: %d -> %d, interval:%d -> %d, read_timeout:%d -> %d]", this->_monitor_threshold, r->get_monitor_threshold(), this->_monitor_interval, r->get_monitor_interval(), this->_monitor_read_timeout, r->get_monitor_read_timeout());
		this->_monitor_threshold = r->get_monitor_threshold();
		this->_monitor_interval = r->get_monitor_interval();
		this->_monitor_read_timeout = r->get_monitor_read_timeout();
	} else if (q->get_ident() == "node_sync") {
		if (this->_down_state >= this->_monitor_threshold && this->_connection->is_available() == false) {
			log_info("node seems realy down -> skip processing queue (node_server_name=%s, node_server_port=%d, ident=%s)", this->_node_server_name.c_str(), this->_node_server_port, q->get_ident().c_str());
			return -1;
		}
		shared_queue_node_sync r = boost::dynamic_pointer_cast<queue_node_sync, thread_queue>(q);
		return r->run(this->_connection);
	} else {
		log_warning("unknown queue [ident=%s] -> skip processing", q->get_ident().c_str());
		return -1;
	}

	return 0;
}

int handler_monitor::_down() {
	this->_down_state++;
	log_debug("node seems down (down_state=%d)", this->_down_state);

	// not >= but == (somehow dangerous?)
	if (this->_down_state == this->_monitor_threshold) {
		log_info("down_state == threshold -> dispatch node down event (down_state=%d, threshold=%d)", this->_down_state, this->_monitor_threshold);
		this->_cluster->request_down_node(this->_node_server_name, this->_node_server_port);
	}

	return 0;
}

int handler_monitor::_up() {
	if (this->_down_state >= this->_monitor_threshold) {
		log_info("node seems up -> dispatch node up event", 0);
		this->_cluster->request_up_node(this->_node_server_name, this->_node_server_port);
	}
	this->_down_state = 0;

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
