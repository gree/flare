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
 *	handler_proxy.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_PROXY_H
#define	HANDLER_PROXY_H

#include <string>

#include <boost/lexical_cast.hpp>

#include "connection.h"
#include "thread_handler.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	proxy thread handler class
 */
class handler_proxy : public thread_handler {
protected:
	cluster*						_cluster;
	shared_connection		_connection;
	const string				_node_server_name;
	const int						_node_server_port;
	int									_noreply_count;
	bool								_skip_proxy;
	bool								_idle_closed;
	uint64_t						_last_used_ms;		// monotonic, last forward sent on _connection

public:
	// connect deadline and retries of a forwarding connection (bounded: a
	// connect that never answers must not hold every queued forward)
	static const int proxy_connect_timeout_ms = 3000;
	static const int proxy_connect_retry_limit = 1;
	// a sender whose connection failed to open this recently drops (counted)
	// at once instead of queueing behind another connect attempt
	static const int proxy_fail_fast_window_ms = 2000;
	// a forwarding connection this node opened and has not used for this
	// long is closed by THIS side (the sender); the next forward opens it
	// again. The receiving side keeps an idle connection for its client idle
	// timeout (net_read_timeout, 600 s) — that is for clients, and a peer's
	// idle forwarding connection held there kept a cordon move waiting for
	// curr_connections == 0 (E2E 43200043205). Settable for the tests.
	static int proxy_idle_close_sec;

	handler_proxy(shared_thread t, cluster* cl, string node_server_name, int node_server_port);
	virtual ~handler_proxy();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_PROXY_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
