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
 *	handler_mysql_replication.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef HANDLER_MYSQL_REPLICATION_H
#define HANDLER_MYSQL_REPLICATION_H

#include "flared.h"

#ifdef ENABLE_MYSQL_REPLICATION

namespace gree {
namespace flare {

/**
 *	flare mysql_replication handler class
 */
class handler_mysql_replication : public thread_handler {
protected:
	cluster*		_cluster;

public:
	handler_mysql_replication(shared_thread t, cluster* c);
	virtual ~handler_mysql_replication();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif // ENABLE_MYSQL_REPLICATION

#endif // HANDLER_MYSQL_REPLICATION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
