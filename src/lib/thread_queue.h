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
 *	thread_queue.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	THREAD_QUEUE_H
#define	THREAD_QUEUE_H

#include <string>

#include <boost/shared_ptr.hpp>

#include "logger.h"
#include "util.h"
#include "connection.h"

namespace gree {
namespace flare {

class thread_queue;
typedef boost::shared_ptr<gree::flare::thread_queue> shared_thread_queue;

/**
 *	thread queue base class
 */
class thread_queue {
protected:
	string							_ident;
	bool								_sync;
	int									_sync_ref_count;
	bool								_success;
	pthread_mutex_t			_mutex_sync;
	pthread_cond_t			_cond_sync;
	time_t							_timestamp;

public:
	thread_queue();
	thread_queue(string ident);
	virtual ~thread_queue();

	virtual int run(shared_connection c);

	int sync();
	int sync_ref();
	int sync_unref();

	virtual string get_ident() { return this->_ident; };
	bool is_success() { return this->_success; };
	time_t get_timestamp() { return this->_timestamp; };
};

}	// namespace flare
}	// namespace gree

#endif	// THREAD_QUEUE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
