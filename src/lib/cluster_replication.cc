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
#include "queue_forward_query.h"

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
		_sync (false) {
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

	cluster::node n = cl->get_node(cl->get_server_name(), cl->get_server_port());
	if (n.node_role == cluster::role_proxy) {
		log_warning("unavailable to start cluster replication becuase this node is proxy node", 0);
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

	this->_start_dump_replication(server_name, server_port, st, cl);

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
int cluster_replication::on_pre_proxy_read(op_proxy_read* op) {
	// nothing to do
	return 0;
}

/**
 *	implementation of on_pre_proxy_write event handling.
 */
int cluster_replication::on_pre_proxy_write(op_proxy_write* op) {
	// nothing to do
	return 0;
}

/**
 *	implementation of on_post_proxy_write event handling.
 */
int cluster_replication::on_post_proxy_write(op_proxy_write* op) {
	pthread_mutex_lock(&this->_mutex_started);
	if (!this->_started) {
		pthread_mutex_unlock(&this->_mutex_started);
		return -1;
	}
	pthread_mutex_unlock(&this->_mutex_started);

	storage::entry& e = op->get_entry();
	shared_thread_queue q(new queue_forward_query(e, op->get_ident()));

	thread_pool::local_map m = this->_thread_pool->get_active(thread_pool::thread_type_cluster_replication);
	if (m.size() == 0) {
		log_notice("no available thread to proxy", 0);
		return -1;
	}

	shared_thread t;
	int key_hash_value = e.get_key_hash_value(storage::hash_algorithm_murmur);
	int index = key_hash_value % m.size();
	int i = 0;
	for (thread_pool::local_map::iterator it = m.begin(); it != m.end(); it++) {
		if (i == index) {
			t = it->second;
			break;
		}
		i++;
	}

	if (this->_sync) {
		q->sync_ref();
	}
	if (t->enqueue(q) < 0) {
		log_warning("enqueue failed (perhaps thread is now exiting?)", 0);
		if (this->_sync) {
			q->sync_unref();
		}
		return -1;
	}
	if (this->_sync) {
		q->sync();
	}

	return 0;
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
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
