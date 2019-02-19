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
 *	thread_pool.cc
 *
 *	implementation of gree::flare::thread_pool
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "thread_pool.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for thread_pool
 */
thread_pool::thread_pool(thread_pool::pool::size_type max_pool_size, int stack_size, AtomicCounter* thread_index):
		_index(thread_index),
		_max_pool_size(max_pool_size),
		_stack_size(stack_size) {
	this->_global_map.clear();

	pthread_rwlock_init(&this->_mutex_global_map, NULL);
	pthread_rwlock_init(&this->_mutex_pool, NULL);
}

/**
 *	dtor for thread_pool
 */
thread_pool::~thread_pool() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	get thread object from pool
 */
shared_thread thread_pool::get(int type) {
	shared_thread tmp;

	pthread_rwlock_wrlock(&this->_mutex_pool);
	pool::size_type pool_size = this->_pool.size();
	log_debug("current pool size: %d", pool_size);
	if (pool_size > 0) {
		tmp = this->_pool.top();
		this->_pool.pop();
		log_debug("thread object from pool (thread_id=%u)", tmp->get_thread_id());
	}
	pthread_rwlock_unlock(&this->_mutex_pool);
	if (pool_size <= 0) {
		tmp = this->_create_thread();
		if (tmp->get_thread_id() == 0) {
			log_err("failed to create thread (thread_id=%d)", tmp->get_thread_id());
			return tmp;
		}
		log_debug("new thread object (thread_id=%u)", tmp->get_thread_id());
	}
	
	unsigned int id;
	pthread_rwlock_wrlock(&this->_mutex_global_map);
	for (;;) {
		id=this->_index->incr();
		if (id == 0) {
			continue;
		}
		bool dup = false;
		for (global_map::iterator it = this->_global_map.begin(); it != this->_global_map.end(); it++) {
			if (it->second.find(id) != it->second.end()) {
				dup = true;
				break;
			}
		}
		if (dup) {
			log_info("thread id [%u] is already in use -> retry...", id);
			continue;
		}

		tmp->setup(type, id);

		this->_global_map[type][tmp->get_id()] = tmp;
		log_debug("adding thread object to global map (type=%d)", type);
		break;
	}
	pthread_rwlock_unlock(&this->_mutex_global_map);

	return tmp;
}

/**
 *	get active thread object from map by id
 */
int thread_pool::get_active(unsigned int id, shared_thread& t) {
	int r = -1;
	pthread_rwlock_rdlock(&this->_mutex_global_map);
	for (global_map::iterator it = this->_global_map.begin(); it != this->_global_map.end(); it++) {
		local_map::iterator it_local = it->second.find(id);
		if (it_local != it->second.end()) {
			t = it_local->second;
			r = 0;
			break;
		}
	}
	pthread_rwlock_unlock(&this->_mutex_global_map);

	return r;
}

/**
 *	get active threads object from map by type
 */
thread_pool::local_map thread_pool::get_active(int type) {
	local_map m;

	pthread_rwlock_rdlock(&this->_mutex_global_map);
	if (this->_global_map.count(type) > 0) {
		m = this->_global_map[type];
	}
	pthread_rwlock_unlock(&this->_mutex_global_map);

	return m;
}

/**
 *	clean up thread activity
 */
int thread_pool::clean(thread* t, bool& is_pool) {
	unsigned int id = t->get_id();
	pthread_t thread_id = t->get_thread_id();
	int type = t->get_type();

	shared_thread tmp;
	pthread_rwlock_wrlock(&this->_mutex_global_map);
	log_debug("removing thread object from global map (type=%d, id=%u, thread_id=%u)", type, id, thread_id);
	if (this->_global_map[type].count(id) == 0) {
		log_warning("specified id not found in global map (type=%d, id=%u, thread_id=%u)", type, id, thread_id);
		is_pool = false;
		pthread_rwlock_unlock(&this->_mutex_global_map);
		return 0;
	}
	tmp = this->_global_map[type][id];
	this->_global_map[type].erase(id);
	tmp->clean_internal();
	pthread_rwlock_unlock(&this->_mutex_global_map);

	pthread_rwlock_wrlock(&this->_mutex_pool);
	if (this->_pool.size() < this->get_max_pool_size()) {
		log_debug("adding thread object to pool (thread_id=%u)", thread_id);
		this->_pool.push(tmp);
		is_pool = true;
	} else {
		log_debug("pool has already enough objects -> skip pooling", 0);
		is_pool = false;
	}
	pthread_rwlock_unlock(&this->_mutex_pool);

	return 0;
}

/**
 *	shutdown all threads
 */
int thread_pool::shutdown() {
	// shutdown active threads
	pthread_rwlock_wrlock(&this->_mutex_global_map);
	for (global_map::iterator it = this->_global_map.begin(); it != this->_global_map.end(); it++) {
		log_debug("shutting down active threads (type=%d, n=%d)", it->first, it->second.size());
		for (local_map::iterator it_local = it->second.begin(); it_local != it->second.end(); it_local++) {
			it_local->second->shutdown();
		}
		this->_global_map[it->first].clear();
	}
	this->_global_map.clear();
	pthread_rwlock_unlock(&this->_mutex_global_map);

	// shutdown pool threads
	shared_thread t;
	pthread_rwlock_wrlock(&this->_mutex_pool);
	log_debug("shutting down pool threads (n=%d)", this->_pool.size());
	while (this->_pool.size() > 0) {
		t = this->_pool.top();
		t->shutdown();
		this->_pool.pop();
	}
	pthread_rwlock_unlock(&this->_mutex_pool);

	return 0;
}

/**
 *	get number of *all* active threads
 */
thread_pool::global_map::size_type thread_pool::get_thread_size() {
	global_map::size_type n = 0;

	pthread_rwlock_rdlock(&this->_mutex_global_map);
	for (global_map::iterator it = this->_global_map.begin(); it != this->_global_map.end(); it++) {
		n += it->second.size();
	}
	pthread_rwlock_unlock(&this->_mutex_global_map);

	log_debug("current thread size (all)=%d", n);

	return n;
}

/**
 *	get thread info
 */
vector<thread::thread_info> thread_pool::get_thread_info() {
	vector<thread::thread_info> list;

	thread::thread_info ti;
	pthread_rwlock_rdlock(&this->_mutex_global_map);
	for (global_map::iterator it = this->_global_map.begin(); it != this->_global_map.end(); it++) {
		for (local_map::iterator it_local = it->second.begin(); it_local != it->second.end(); it_local++) {
			list.push_back(it_local->second->get_thread_info());
		}
	}
	pthread_rwlock_unlock(&this->_mutex_global_map);

	return list;
}

/**
 *	get thread info
 */
vector<thread::thread_info> thread_pool::get_thread_info(int type) {
	vector<thread::thread_info> list;

	thread::thread_info ti;
	pthread_rwlock_rdlock(&this->_mutex_global_map);
	for (local_map::iterator it = this->_global_map[type].begin(); it != this->_global_map[type].end(); it++) {
		list.push_back(it->second->get_thread_info());
	}
	pthread_rwlock_unlock(&this->_mutex_global_map);

	return list;
}

/**
 *	get number of active threads
 */
thread_pool::global_map::size_type thread_pool::get_thread_size(int type) {
	pthread_rwlock_rdlock(&this->_mutex_global_map);
	global_map::size_type n = this->_global_map[type].size();
	pthread_rwlock_unlock(&this->_mutex_global_map);

	log_debug("current thread size=%d", n);

	return n;
}

/**
 *	get number of pool threads
 */
thread_pool::pool::size_type thread_pool::get_pool_size() {
	pthread_rwlock_rdlock(&this->_mutex_pool);
	pool::size_type n = this->_pool.size();
	pthread_rwlock_unlock(&this->_mutex_pool);

	log_debug("current pool size=%d", n);

	return n;
}
// }}}

// {{{ protected methods
/**
 *	create thread object
 */
shared_thread thread_pool::_create_thread() {
	shared_thread t(new thread(this));
	weak_thread weak_t(t);
	t->startup(weak_t, this->_stack_size);

	return t;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
