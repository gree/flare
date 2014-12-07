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
 *	handler_dump_replication.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_DUMP_REPLICATION_H
#define	HANDLER_DUMP_REPLICATION_H

#include <string>

#include "connection.h"
#include "cluster.h"
#include "storage.h"
#include "thread_handler.h"
#include "bwlimitter.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	thread handler class to replicate the dumped storage data
 **/
class handler_dump_replication : public thread_handler {
protected:
	cluster*									_cluster;
	storage*									_storage;
	const string							_replication_server_name;
	const int									_replication_server_port;
	shared_connection					_connection;
	bwlimitter								_bwlimitter;

public:
	handler_dump_replication(shared_thread t, cluster* cl, storage* st, string server_name, int server_port);
	virtual ~handler_dump_replication();

	virtual int run();

protected:

private:
	long _sleep_for_bwlimit(int bytes_written, int bwlimit);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_DUMP_REPLICATION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
