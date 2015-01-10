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

namespace gree {
namespace flare {

/**
 *	class to handle replication over cluster
 **/
class cluster_replication : public proxy_event_listener {
private:
	thread_pool*			_thread_pool;
	string						_server_name;
	int								_server_port;
	int								_concurrency;
	bool							_started;
	bool							_sync;
	pthread_mutex_t		_mutex_started;

public:
	cluster_replication(thread_pool* tp);
	virtual ~cluster_replication();

	bool is_started() { return this->_started; };
	int start(string server_name, int server_port, int concurrency, storage* st, cluster* cl, bool skip_dump = false);
	int stop();

	int set_sync(bool sync) { this->_sync = sync; return 0; };
	bool get_sync() { return this->_sync; };
	string get_server_name() { return this->_server_name; };
	int get_server_port() { return this->_server_port; };
	int get_concurrency() { return this->_concurrency; };

	virtual int on_pre_proxy_read(op_proxy_read* op);
	virtual int on_pre_proxy_write(op_proxy_write* op);
	virtual int on_post_proxy_write(op_proxy_write* op);

private:
	int _start_dump_replication(string server_name, int server_port, storage* st, cluster* cl);
	int _stop_dump_replication();
};

}	// namespace flare
}	// namespace gree

#endif	// CLUSTER_RPLICATION
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
