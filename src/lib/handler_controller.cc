/**
 *	handler_controller.cc
 *
 *	implementation of gree::flare::handler_controller
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#include "handler_controller.h"
#include "queue_node_state.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_monitor
 */
handler_controller::handler_controller(shared_thread t, cluster* cl):
		thread_handler(t),
		_cluster(cl) {
}

/**
 *	dtor for handler_controller
 */
handler_controller::~handler_controller() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_controller::run() {
	for (;;) {
		this->_thread->set_state("wait");
		this->_thread->set_op("");

		shared_thread_queue q;
		if (!this->_thread->is_shutdown_request()) {
			// dequeue
			if (this->_thread->dequeue(q, 0) < 0) {
				continue;
			}
		}
		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0); 
			this->_thread->set_state("shutdown");
			break;
		}

		this->_process_queue(q);
		q->sync_unref();
	}

	return 0;
}
// }}}

// {{{ protected methods
int handler_controller::_process_queue(shared_thread_queue q) {
	log_debug("queue: %s", q->get_ident().c_str());
	this->_thread->set_state("execute");
	this->_thread->set_op(q->get_ident());

	if (q->get_ident() == "node_state") {
		shared_queue_node_state r = dynamic_pointer_cast<queue_node_state, thread_queue>(q);
		if (r) {
			if (r->get_operation() == queue_node_state::state_operation_down) {
				this->_cluster->down_node(r->get_node_server_name(), r->get_node_server_port());
			} else if (r->get_operation() == queue_node_state::state_operation_up) {
				this->_cluster->up_node(r->get_node_server_name(), r->get_node_server_port());
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
