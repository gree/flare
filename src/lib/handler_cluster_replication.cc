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
 *	handler_cluster_replication.cc
 *
 *	implementation of gree::flare::handler_cluster_replication
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#include "handler_cluster_replication.h"
#include "handler_proxy.h"
#include "queue_proxy_write.h"
#include "connection_tcp.h"

#include <boost/lexical_cast.hpp>

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_cluster_replication
 */
handler_cluster_replication::handler_cluster_replication(shared_thread t, string server_name, int server_port):
		thread_handler(t),
		_replication_server_name(server_name),
		_replication_server_port(server_port) {
}

/**
 *	dtor for handler_cluster_replication
 */
handler_cluster_replication::~handler_cluster_replication() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_cluster_replication::run() {
	this->_thread->set_peer(this->_replication_server_name, this->_replication_server_port);
	this->_thread->set_state("connect");

	connection_tcp* ctp = new connection_tcp(
			   this->_replication_server_name, this->_replication_server_port);
	// Bounded like the in-cluster forwarding connection (handler_proxy): the
	// default connect is blocking with 8 retries, so a destination that does
	// not answer SYNs (an LB address with no backend, a black-holed route)
	// held this thread ~130 s per attempt, up to 9 attempts per open and 4
	// opens per forward, with every later forward queued behind it — not
	// sent, not counted. Bounded, a timed-out open makes the next forwards
	// fail fast (counted) instead. The read side is connection_tcp's read
	// timeout (30 s in the k8s build unless net-read-timeout is set).
	ctp->set_connect_timeout_ms(handler_proxy::proxy_connect_timeout_ms);
	ctp->set_connect_retry_limit(handler_proxy::proxy_connect_retry_limit);
	shared_connection c(ctp);
	this->_connection = c;
	if (c->open() < 0) {
		// The thread STAYS (it used to return here: it left the pool for good
		// while the replication stayed 'started', so a destination that was
		// unreachable at start — e.g. its name not yet in DNS — made every
		// later forward an uncounted "no available thread" drop until a
		// restart or a disable/enable). Each queued forward reconnects on its
		// own (queue_proxy_write::run) and is counted as dropped while the
		// destination stays unreachable.
		log_err("failed to connect to cluster replication destination server (name=%s, port=%d) — the forwarding thread stays; each forward reconnects",
				   this->_replication_server_name.c_str(), this->_replication_server_port);
	}

	for (;;) {
		this->_thread->set_state("wait");
		this->_thread->set_op("");

		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			this->_thread->set_state("shutdown");
			break;
		}

		// dequeue (tentative)
		shared_thread_queue q;
		if (this->_thread->dequeue(q, 0) < 0) {
			log_info("dequeued but no queue is available (something is inconsistent?)", 0);
			continue;
		}
		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			this->_thread->set_state("shutdown");
			// Taken off the queue but never run: the thread's clean-up only
			// sees what is still queued, so this forward ended with NO
			// outcome counted (review 2026-10-12: forward_enqueued above its
			// outcomes for good). Counted like a queued one left behind.
			q->on_abandoned(this->_replication_server_name + ":" + boost::lexical_cast<string>(this->_replication_server_port));
			q->sync_unref();
			break;
		}

		this->_process_queue(q);
		q->sync_unref();
	}

	return 0;
}
// }}}

// {{{ protected methods
int handler_cluster_replication::_process_queue(shared_thread_queue q) {
	this->_thread->set_state("execute");
	this->_thread->set_op(q->get_ident());
	// a forward's retry wait ends when this thread is asked to stop
	if (shared_queue_proxy_write w = boost::dynamic_pointer_cast<queue_proxy_write>(q)) {
		w->set_owner(this->_thread);
	}

	return q->run(this->_connection);
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
