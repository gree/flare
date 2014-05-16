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
#include "connection_tcp.h"
#include "queue_forward_query.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_cluster_replication
 */
handler_cluster_replication::handler_cluster_replication(shared_thread t, cluster* c, string server_name, int server_port):
		thread_handler(t),
		_cluster(c),
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

	shared_connection c(new connection_tcp(this->_replication_server_name, this->_replication_server_port));
	this->_connection = c;
	if (c->open() < 0) {
		log_err("failed to connect to cluster replication server (name=%s, port=%d)", this->_replication_server_name.c_str(), this->_replication_server_port);
		this->_cluster->set_cluster_replication(false);
		return -1;
	}

	for (;;) {
		this->_thread->set_state("wait");
		this->_thread->set_op("");

		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			this->_thread->set_state("shutdown");
			this->_cluster->set_cluster_replication(false);
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
			this->_cluster->set_cluster_replication(false);
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

	shared_queue_forward_query r = dynamic_pointer_cast<queue_forward_query, thread_queue>(q);
	return r->run(this->_connection);
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
