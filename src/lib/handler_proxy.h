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

public:
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
