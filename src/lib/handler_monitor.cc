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
#include <boost/scoped_ptr.hpp>
#include <boost/lexical_cast.hpp>

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
		_down_count(0),
		_node_map_version_mismatch_count(0) {
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
	this->_setup();
	this->_mainloop();

	return 0;
}
// }}}

// {{{ protected methods
void handler_monitor::_setup() {
	this->_thread->set_peer(this->_node_server_name, this->_node_server_port);
	this->_thread->set_state("connect");

	shared_connection c(new connection_tcp(this->_node_server_name, this->_node_server_port));
	this->_connection = c;
	this->_connection->set_connect_retry_limit(0);

	if (c->open() < 0) {
		log_err("failed to connect to node server [name=%s, port=%d]", this->_node_server_name.c_str(), this->_node_server_port);
		this->_down();
	}
}

void handler_monitor::_mainloop() {
	for (;;) {
		if (this->_main() != 0) {
			break;
		}
	}
}

int handler_monitor::_main() {
	this->_thread->set_state("wait");
	this->_thread->set_op("");

	if (this->_thread->is_shutdown_request()) {
		log_info("thread shutdown request -> breaking loop", 0);
		this->_thread->set_state("shutdown");
		return 1;
	}

	// dequeue
	shared_thread_queue q;
	int r = this->_thread->dequeue(q, this->_monitor_interval);
	if (this->_thread->is_shutdown_request()) {
		log_info("thread shutdown request -> breaking loop", 0);
		this->_thread->set_state("shutdown");
		return 1;
	}

	// sync w/ node_map for safe
	cluster::node n = this->_cluster->get_node(this->_node_server_name, this->_node_server_port);
	if (n.node_server_name == this->_node_server_name) {
		if (n.node_state == cluster::state_down) {
			this->_down_count = this->_monitor_threshold;
		} else if (this->_down_count >= this->_monitor_threshold) {
			this->_down_count = 0;
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

	return 0;
}

int handler_monitor::_process_monitor() {
	if (this->_connection->is_available() == false) {
		log_info("connection for %s:%d is unavailable -> re-opening...", this->_node_server_name.c_str(), this->_node_server_port);
		if (this->_connection->open() < 0) {
			return -1;
		}
	}

	int current_read_timeout = this->_connection->get_read_timeout();

	this->_connection->set_read_timeout(0);
	this->_clear_read_buf();
	this->_connection->set_read_timeout(this->_monitor_read_timeout);

	stats_results stats_results;
	if (this->_request_stats(stats_results) < 0) {
		this->_connection->set_read_timeout(current_read_timeout);
		return -1;
	}

	this->_process_node_map_version(stats_results);

	switch (this->_get_node_status(stats_results)) {
	case node_status_result_ok:
		// normally. do nothing
		break;
	case node_status_result_ng:
		this->_connection->set_read_timeout(current_read_timeout);
		return -1;
	case node_status_not_found:
		// fallback to op_ping for compatibility
		if (this->_request_ping() < 0) {
			this->_connection->set_read_timeout(current_read_timeout);
			return -1;
		}
		break;
	}

	this->_connection->set_read_timeout(current_read_timeout);
	return 0;
}

int handler_monitor::_process_queue(shared_thread_queue q) {
	log_debug("queue: %s", q->get_ident().c_str());
	this->_thread->set_state("execute");
	this->_thread->set_op(q->get_ident());

	if (q->get_ident() == "update_monitor_option") {
		shared_queue_update_monitor_option r = boost::dynamic_pointer_cast<queue_update_monitor_option, thread_queue>(q);
		log_debug("updating monitor option [threshold: %d -> %d, interval:%d -> %d, read_timeout:%d -> %d]",
			this->_monitor_threshold, r->get_monitor_threshold(),
			this->_monitor_interval, r->get_monitor_interval(),
			this->_monitor_read_timeout, r->get_monitor_read_timeout(),
		);
		this->_monitor_threshold = r->get_monitor_threshold();
		this->_monitor_interval = r->get_monitor_interval();
		this->_monitor_read_timeout = r->get_monitor_read_timeout();
	} else if (q->get_ident() == "node_sync") {
		if (this->_down_count >= this->_monitor_threshold && this->_connection->is_available() == false) {
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
	if (_tick_down() == should_modify_state) {
		this->_cluster->request_down_node(this->_node_server_name, this->_node_server_port);
	}

	return 0;
}

int handler_monitor::_up() {
	if (_tick_up() == should_modify_state) {
		this->_cluster->request_up_node(this->_node_server_name, this->_node_server_port);
	}

	return 0;
}


handler_monitor::tick_result handler_monitor::_tick_down() {
	this->_down_count++;
	log_debug("node seems down (down_state=%d)", this->_down_count);

	// not >= but == (somehow dangerous?)
	if (this->_down_count == this->_monitor_threshold) {
		log_info("down_state == threshold -> dispatch node down event (down_state=%d, threshold=%d)", this->_down_count, this->_monitor_threshold);
		return should_modify_state;
	}

	return keep_state;
}

handler_monitor::tick_result handler_monitor::_tick_up() {
	if (this->_down_count >= this->_monitor_threshold) {
		log_info("node seems up -> dispatch node up event", 0);
		this->_down_count = 0;
		return should_modify_state;
	}
	this->_down_count = 0;
	return keep_state;
}

void handler_monitor::_process_node_map_version(const stats_results& results) {
	stats_results::const_iterator result = results.find("flare_node_map_version");
	if (result == results.end()) {
		return;
	}
	uint64_t version;
	try {
		version = boost::lexical_cast<uint64_t>(result->second);
	} catch (boost::bad_lexical_cast&) {
		log_debug("invalid version");
		return;
	}
	this->_update_node_map_version_match_count(version);
}

handler_monitor::node_status handler_monitor::_get_node_status(const stats_results &results) {
	stats_results::const_iterator result = results.find("flare_node_status");
	if (result == results.end()) {
		return node_status_not_found;
	}
	if (result->second != "OK") {
		return node_status_result_ng;
	}
	return node_status_result_ok;
}

void handler_monitor::_update_node_map_version_match_count(uint64_t version) {
	if (this->_cluster->get_node_map_version() == version) {
		this->_node_map_version_mismatch_count = 0;
		return;
	}

	this->_node_map_version_mismatch_count++;

	if (this->_is_node_map_version_mismatch_over_threshold()) {
		log_err(
			"node_map_version seems mismatched (current_index_server:%"PRIu64", node(%s:%d):%"PRIu64")",
			this->_cluster->get_node_map_version(),
			this->_node_server_name.c_str(),
			this->_node_server_port,
			version
		);
	}
}

bool handler_monitor::_is_node_map_version_mismatch_over_threshold() {
	static const double mismatch_threshold_sec = 30;
	const uint64_t mismatch_threshold = static_cast<uint64_t>(ceil(mismatch_threshold_sec / this->_monitor_interval));
	return this->_node_map_version_mismatch_count >= mismatch_threshold;
}

int handler_monitor::_request_stats(stats_results &results) {
	boost::scoped_ptr<op_stats> op(new op_stats(this->_connection));
	this->_thread->set_state("execute");
	this->_thread->set_op(op->get_ident());
	return op->run_client(results);
}

int handler_monitor::_request_ping() {
	boost::scoped_ptr<op_ping> op(new op_ping(this->_connection));
	this->_thread->set_state("execute");
	this->_thread->set_op(op->get_ident());
	return op->run_client();
}

void handler_monitor::_clear_read_buf() {
	// clear read buf
	char* tmp;
	bool actual;
	if (this->_connection->read(&tmp, -1, false, actual) > 0) {
		delete[] tmp;
	}
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
