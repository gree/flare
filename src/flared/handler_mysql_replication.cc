/**
 *	handler_mysql_replication.cc
 *	
 *	implementation of gree::flare::handler_mysql_replication
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "handler_mysql_replication.h"

#ifdef ENABLE_MYSQL_REPLICATION
#include "mysql_replication.h"
#include "queue_proxy_write.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for handler_mysql_replication
 */
handler_mysql_replication::handler_mysql_replication(shared_thread t):
		thread_handler(t) {
}

/**
 *	dtor for handler_mysql_replication
 */
handler_mysql_replication::~handler_mysql_replication() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	run thread proc
 */
int handler_mysql_replication::run() {
	this->_thread->set_state("wait"); 
	this->_thread->set_op("");

	server* s = _new_ server();
	if (s->listen(ini_option_object().get_mysql_replication_port()) < 0) {
		_delete_(s);
		return -1;
	}

	for (;;) {
		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			break;
		}

		vector<shared_connection> connection_list = s->wait();
		vector<shared_connection>::iterator it;
		for (it = connection_list.begin(); it != connection_list.end(); it++) {
			shared_connection c = *it;

			mysql_replication* m = _new_ mysql_replication(this->_thread, c, ini_option_object().get_mysql_replication_id(), ini_option_object().get_mysql_replication_db(), ini_option_object().get_mysql_replication_table());
			if (m->handshake() < 0) {
				_delete_(m);
				continue;
			}

			if (m->parse() < 0) {
				_delete_(m);
				continue;
			}

			for (;;) {
				if (this->_thread->is_shutdown_request()) {
					log_info("thread shutdown request -> breaking loop", 0);
					this->_thread->set_state("shutdown");
					break;
				}

				// dequeue
				shared_thread_queue q;
				if (this->_thread->dequeue(q, 0) < 0) {
					 log_info("dequeued but no queue is available (something is inconsistent?", 0);
					 continue;
				}
				if (this->_thread->is_shutdown_request()) {
					log_info("thread shutdown request -> breaking loop", 0);
					this->_thread->set_state("shutdown");
					break;
				}

				// process
				if (this->_process_queue(q) < 0) {
					q->sync_unref();
					break;
				}
				shared_queue_proxy_write r = shared_dynamic_cast<queue_proxy_write, thread_queue>(q);
				m->send(r);
				q->sync_unref();
			}

			_delete_(m);
		}
	}

	_delete_(s);

	return 0;
}
// }}}

// {{{ protected methods
int handler_mysql_replication::_process_queue(shared_thread_queue q) { 
	log_debug("queue: %s", q->get_ident().c_str());
	this->_thread->set_state("execute");
	this->_thread->set_op(q->get_ident());

	if (q->get_ident() == "proxy_read") {
		// nothing to do
	} else if (q->get_ident() == "proxy_write") {
		return 0;
	} else {
		log_warning("unknown queue [ident=%s] -> skip processing", q->get_ident().c_str());
	}

	return -1;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree
#endif	// ENABLE_MYSQL_REPLICATION
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
