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
 *	cluster_replication.cc
 *
 *	implementation of gree::flare::cluster_replication
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#include "cluster_replication.h"
#include "handler_cluster_replication.h"
#include "handler_dump_replication.h"
#include "logger.h"
#include "op_proxy_read.h"
#include "op_proxy_write.h"
#include "queue_proxy_read.h"
#include "queue_proxy_write.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for cluster_replication
 */
cluster_replication::cluster_replication(thread_pool* tp):
		_thread_pool(tp),
		_server_name(""),
		_server_port(0),
		_concurrency(0),
		_started(false),
		_mode (mode_duplicate) {
	pthread_mutex_init(&this->_mutex_started, NULL);
}

/**
 *	dtor for cluster_replicationplication
 */
cluster_replication::~cluster_replication() {
	this->stop();
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	start cluster replication.
 */
int cluster_replication::start(string server_name, int server_port, int concurrency, storage* st, cluster* cl) {
	log_notice("start cluster replication (dest=%s:%d, concurrency=%d)", server_name.c_str(), server_port, concurrency);

	if (this->_started) {
		log_debug("cluster replication is already started", 0);
		return -1;
	}

	if (concurrency <= 0) {
		log_warning("concurrency is not valid, concurrency=%d", concurrency);
		return -1;
	}

	for (int i = 0; i < concurrency; i++) {
		shared_thread t = this->_thread_pool->get(thread_pool::thread_type_cluster_replication);
		handler_cluster_replication* h = new handler_cluster_replication(t, server_name, server_port);
		t->trigger(h);
	}
	pthread_mutex_lock(&this->_mutex_started);
	this->_started = true;
	pthread_mutex_unlock(&this->_mutex_started);

	this->_server_name = server_name;
	this->_server_port = server_port;
	this->_concurrency = concurrency;

	cluster::node n = cl->get_node(cl->get_server_name(), cl->get_server_port());
	if (this->_mode == mode_duplicate && n.node_role == cluster::role_master) {
		// replicate the dump data over cluster when the mode of master server is duplicate
		this->_start_dump_replication(server_name, server_port, st, cl);
	} else {
		log_notice("skip to start dump replication, dump is started only when node is master and mode is duplicate", 0);
	}

	return 0;
}

/**
 *	stop cluster replication.
 */
int cluster_replication::stop() {
	log_notice("stop cluster replication", 0);

	pthread_mutex_lock(&this->_mutex_started);
	this->_started = false;
	pthread_mutex_unlock(&this->_mutex_started);

	this->_server_name = "";
	this->_server_port = 0;
	this->_concurrency = 0;

	thread_pool::local_map m = this->_thread_pool->get_active(thread_pool::thread_type_cluster_replication);
	for (thread_pool::local_map::iterator it = m.begin(); it != m.end(); it++) {
		log_debug("killing cluster replication thread", 0);
		it->second->set_state("killed");
		it->second->shutdown(true, false);
	}

	this->_stop_dump_replication();

	return 0;
}

/**
 *	implementation of on_pre_proxy_read event handling.
 */
cluster::proxy_request cluster_replication::on_pre_proxy_read(op_proxy_read* op, storage::entry& e, void* parameter, shared_queue_proxy_read& q_result) {
	pthread_mutex_lock(&this->_mutex_started);
	if (!this->_started) {
		pthread_mutex_unlock(&this->_mutex_started);
		return cluster::proxy_request_continue;
	}
	pthread_mutex_unlock(&this->_mutex_started);

	if (this->_mode == mode_forward) {
		// forwarding read query only when mode is forward
		// not depend on the role of server
		vector<string> proxy = op->get_proxy();
		shared_queue_proxy_read q(new queue_proxy_read(NULL, NULL, proxy, e, parameter, op->get_ident()));
		int key_hash_value = e.get_key_hash_value(storage::hash_algorithm_murmur);
		if (this->_enqueue(q, key_hash_value, true)) {
			return cluster::proxy_request_error_enqueue;
		}
		q_result = q;

		return cluster::proxy_request_complete;
	}

	return cluster::proxy_request_continue;
}

/**
 *	implementation of on_pre_proxy_write event handling.
 */
cluster::proxy_request cluster_replication::on_pre_proxy_write(op_proxy_write* op, storage::entry& e, shared_queue_proxy_write& q_result, uint64_t generic_value) {
	pthread_mutex_lock(&this->_mutex_started);
	if (!this->_started) {
		pthread_mutex_unlock(&this->_mutex_started);
		return cluster::proxy_request_continue;
	}
	pthread_mutex_unlock(&this->_mutex_started);

	if (this->_mode == mode_forward) {
		// forwarding write query only when mode is forward
		// not depend on the role of server
		vector<string> proxy = op->get_proxy();
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, op->get_ident()));
		int key_hash_value = e.get_key_hash_value(storage::hash_algorithm_murmur);
		if (this->_enqueue(q, key_hash_value, true)) {
			return cluster::proxy_request_error_enqueue;
		}
		q->sync();
		q_result = q;

		return cluster::proxy_request_complete;
	}

	return cluster::proxy_request_continue;
}

/**
 *	implementation of on_post_proxy_write event handling.
 */
cluster::proxy_request cluster_replication::on_post_proxy_write(op_proxy_write* op, cluster::node node) {
	pthread_mutex_lock(&this->_mutex_started);
	if (!this->_started) {
		pthread_mutex_unlock(&this->_mutex_started);
		return cluster::proxy_request_continue;
	}
	pthread_mutex_unlock(&this->_mutex_started);

	if (node.node_role == cluster::role_master) {
		// replicate over cluster only when master
		// not depend on mode of master
		storage::entry& e = op->get_entry();
		vector<string> proxy = op->get_proxy();
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, op->get_ident()));
		q->set_post_proxy(true);

		int key_hash_value = e.get_key_hash_value(storage::hash_algorithm_murmur);
		if (this->_enqueue(q, key_hash_value, false) < 0) {
			return cluster::proxy_request_continue;
		}
	}

	return cluster::proxy_request_continue;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
/**
 *	start to replicate the dump of storage.
 */
int cluster_replication::_start_dump_replication(string server_name, int server_port, storage* st, cluster* cl) {
	log_notice("start to replicate the dump of storage", 0);
	shared_thread t = this->_thread_pool->get(thread_pool::thread_type_dump_replication);
	handler_dump_replication* h = new handler_dump_replication(t, cl, st, server_name, server_port);
	t->trigger(h);
	return 0;
}

/**
 *	stop to replicate the dump of storage.
 */
int cluster_replication::_stop_dump_replication() {
	log_notice("stop replication of the dump of storage", 0);
	thread_pool::local_map m = this->_thread_pool->get_active(thread_pool::thread_type_dump_replication);
	for (thread_pool::local_map::iterator it = m.begin(); it != m.end(); it++) {
		log_debug("killing dump replication thread", 0);
		it->second->set_state("killed");
		it->second->shutdown(true, false);
	}
	return 0;
}

int cluster_replication::_enqueue(shared_thread_queue q, int key_hash_value, bool sync) {
	log_debug("enqueue (indent=%s)", q->get_ident().c_str());

	thread_pool::local_map m = this->_thread_pool->get_active(thread_pool::thread_type_cluster_replication);
	if (m.size() == 0) {
		log_notice("no available thread to forward queue", 0);
		return -1;
	}

	shared_thread t;
	int index = key_hash_value % m.size();
	int i = 0;
	for (thread_pool::local_map::iterator it = m.begin(); it != m.end(); it++) {
		if (i == index) {
			t = it->second;
			break;
		}
		i++;
	}

	if (sync) {
		q->sync_ref();
	}
	if (t->enqueue(q) < 0) {
		log_warning("enqueue failed (perhaps thread is now exiting?)", 0);
		if (sync) {
			q->sync_unref();
		}
		return -1;
	}

	return 0;
}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
