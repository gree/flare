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
 *	cluster_replication.h
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	CLUSTER_REPLICATION_H
#define	CLUSTER_REPLICATION_H

#include <string>

#include <pthread.h>

#include "cluster.h"
#include "proxy_event_listener.h"
#include "storage.h"
#include "thread_pool.h"

#include "queue_proxy_read.h"
#include "queue_proxy_write.h"

namespace gree {
namespace flare {

/**
 *	class to handle replication over cluster
 **/
class cluster_replication : public proxy_event_listener {
public:
	enum							mode {
			mode_duplicate				= 1,
			mode_forward					= 2,
	};

private:
	thread_pool*			_thread_pool;
	string						_server_name;
	int								_server_port;
	int								_concurrency;
	bool							_started;
	mode							_mode;
	pthread_mutex_t		_mutex_started;

public:
	cluster_replication(thread_pool* tp);
	virtual ~cluster_replication();

	bool is_started() { return this->_started; };
	int start(string server_name, int server_port, int concurrency, storage* st, cluster* cl);
	int stop();

	int set_mode(mode m) { this->_mode = m; return 0; };
	mode get_mode() { return this->_mode; };
	string get_server_name() { return this->_server_name; };
	int get_server_port() { return this->_server_port; };
	int get_concurrency() { return this->_concurrency; };

	virtual cluster::proxy_request on_pre_proxy_read(op_proxy_read* op, storage::entry& e, void* parameter, shared_queue_proxy_read& q_result);
	virtual cluster::proxy_request on_pre_proxy_write(op_proxy_write* op, storage::entry& e, shared_queue_proxy_write& q_result, uint64_t generic_value);
	virtual cluster::proxy_request on_post_proxy_write(op_proxy_write* op, cluster::node node);

	static inline int mode_cast(string s, mode& m) {
		if (s == "duplicate") {
			m = mode_duplicate;
		} else if (s == "forward") {
			m = mode_forward;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string mode_cast(mode m) {
		switch (m) {
		case mode_duplicate:
			return "duplicate";
		case mode_forward:
			return "forward";
		}
		return "";
	};

private:
	int _start_dump_replication(string server_name, int server_port, storage* st, cluster* cl);
	int _stop_dump_replication();
	int _enqueue(shared_thread_queue q, int key_hash_value, bool sync);
};

}	// namespace flare
}	// namespace gree

#endif	// CLUSTER_RPLICATION
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
