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
 *	handler_cluster_replication.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_CLUSTER_REPLICATION_H
#define	HANDLER_CLUSTER_REPLICATION_H

#include <string>

#include <boost/lexical_cast.hpp>

#include "connection.h"
#include "cluster.h"
#include "thread_handler.h"
#include "thread_queue.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	cluster replication thread handler class
 */
class handler_cluster_replication : public thread_handler {
protected:
	string							_replication_server_name;
	int									_replication_server_port;
	shared_connection		_connection;

public:
	handler_cluster_replication(shared_thread t, string server_name, int server_port);
	virtual ~handler_cluster_replication();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_CLUSTER_REPLICATION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
