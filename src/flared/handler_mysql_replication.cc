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
handler_mysql_replication::handler_mysql_replication(shared_thread t, cluster* c):
		thread_handler(t),
		_cluster(c) {
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

	server* s = new server();
	if (s->listen(ini_option_object().get_mysql_replication_port()) < 0) {
		delete s;
		return -1;
	}

	for (;;) {
		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			break;
		}

		vector<shared_connection_tcp> connection_list = s->wait();
		vector<shared_connection_tcp>::iterator it;
		for (it = connection_list.begin(); it != connection_list.end(); it++) {
			shared_connection_tcp c = *it;
			c->set_read_timeout(86400 * 365);

			mysql_replication* m = new mysql_replication(this->_thread, c, ini_option_object().get_mysql_replication_id(), ini_option_object().get_mysql_replication_db(), ini_option_object().get_mysql_replication_table());
			if (m->handshake() < 0) {
				delete m;
				continue;
			}

			if (m->parse() < 0) {
				delete m;
				continue;
			}

			this->_cluster->set_mysql_replication(true);

			for (;;) {
				if (this->_thread->is_shutdown_request()) {
					log_info("thread shutdown request -> breaking loop", 0);
					this->_thread->set_state("shutdown");
					break;
				}

				// dequeue
				shared_thread_queue q;
				int r = this->_thread->dequeue(q, 60);
				if (this->_thread->is_shutdown_request()) {
					log_info("thread shutdown request -> breaking loop", 0);
					this->_thread->set_state("shutdown");
					break;
				}

				if (r == ETIMEDOUT) {
					// see if connection is available
					c->set_read_timeout(0);
					char *tmp;
					bool actual;
					int tmp_len = c->read(&tmp, -1, false, actual);
					if (tmp_len > 0) {
						c->push_back(tmp, tmp_len);
						delete[] tmp;
					}
					c->set_read_timeout(86400 * 365);
					if (c->is_available() == false) {
						log_debug("connection is not available -> breaking loop", 0);
						break;
					}
				} else if (r == 0) {
					// process
					if (this->_process_queue(q) < 0) {
						q->sync_unref();
						break;
					}
					shared_queue_proxy_write r = boost::dynamic_pointer_cast<queue_proxy_write, thread_queue>(q);
					if (m->send(r) < 0) {
						q->sync_unref();
						break;
					}
					q->sync_unref();
				} else {
					// something is going wrong
					break;
				}
			}
			this->_cluster->set_mysql_replication(false);
			delete m;
		}
	}

	delete s;

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
