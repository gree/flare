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
 *	flared.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	FLARED_H
#define	FLARED_H

#include "app.h"
#include "cluster_replication.h"
#include "ini_option.h"
#include "stats_node.h"
#include "status_node.h"
#include "storage_access_info.h"

namespace gree {
namespace flare {

using boost::shared_ptr;

typedef shared_ptr<cluster_replication> shared_cluster_replication;

/**
 *	flared application class
 */
class flared :
	public app,
	public storage_listener {
private:
	server*				_server;
	thread_pool*	_req_thread_pool;
	thread_pool*	_other_thread_pool;
	cluster*			_cluster;
	storage*			_storage;
#ifdef ENABLE_MYSQL_REPLICATION
	server*				_mysql_replication_server;
#endif
	shared_cluster_replication	_cluster_replication;

public:
	flared();
	~flared();

	int startup(int argc, char** argv);
	int run();
	int reload();
	int shutdown();

	thread_pool* get_req_thread_pool() { return this->_req_thread_pool; };
	thread_pool* get_other_thread_pool() { return this->_other_thread_pool; };
	cluster* get_cluster() { return this->_cluster; };
	storage* get_storage() { return this->_storage; };

	virtual void on_storage_error();

protected:
	string _get_pid_path();

private:
	int _set_resource_limit();
	int _set_signal_handler();
};

}	// namespace flare
}	// namespace gree

#endif	// FLARED_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
