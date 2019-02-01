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
 *	thread_pool.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	THREAD_POOL_H
#define	THREAD_POOL_H

#include <map>
#include <stack>
#include <vector>

#include "thread.h"
#include "thread_handler.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	thread pooling class
 */
class thread_pool {
public:
	enum							thread_type {
		thread_type_request = 1,
		thread_type_alarm,
		thread_type_reconstruction,
		thread_type_controller,
		thread_type_cluster_replication,
		thread_type_dump_replication,
#ifdef ENABLE_MYSQL_REPLICATION
		thread_type_mysql_replication,
#endif
	};

	typedef	map<unsigned int, shared_thread>	local_map;
	typedef	map<int, local_map>								global_map;
	typedef	stack<shared_thread>							pool;

protected:
	AtomicCounter*		_index;
	global_map				_global_map;
	pool							_pool;

	pthread_rwlock_t	_mutex_global_map;
	pthread_rwlock_t	_mutex_pool;

	pool::size_type		_max_pool_size;
	int								_stack_size;			// kb

public:
	static const int default_stack_size = 128;

	thread_pool(pool::size_type max_pool_size, int stack_size, AtomicCounter* _thread_index);
	virtual ~thread_pool();

	shared_thread get(int type);
	int get_active(unsigned int id, shared_thread& t);
	local_map get_active(int type);
	int clean(thread* t, bool& is_pool);
	int shutdown();

	vector<thread::thread_info> get_thread_info();
	vector<thread::thread_info> get_thread_info(int type);
	global_map::size_type get_thread_size();
	global_map::size_type get_thread_size(int type);
	pool::size_type get_pool_size();
	int set_max_pool_size(pool::size_type max_pool_size) { this->_max_pool_size = max_pool_size; return 0; };
	pool::size_type get_max_pool_size() { return this->_max_pool_size; };

protected:
	shared_thread _create_thread();
};

}	// namespace flare
}	// namespace gree

#endif	// THREAD_POOL_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
