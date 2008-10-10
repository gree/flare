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

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for thread_pool
 */
thread_pool::thread_pool(thread_pool::pool::size_type max_pool_size):
		_max_pool_size(max_pool_size) {
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
		log_debug("thread object from pool (id=%d)", tmp->get_id());
	}
	pthread_rwlock_unlock(&this->_mutex_pool);
	if (pool_size <= 0) {
		tmp = this->_create_thread();
		log_debug("new thread object (id=%d)", tmp->get_id());
	}
	tmp->setup(type);

	pthread_rwlock_wrlock(&this->_mutex_global_map);
	log_debug("adding thread object to global map (type=%d)", type);
	this->_global_map[type][tmp->get_id()] = tmp;
	pthread_rwlock_unlock(&this->_mutex_global_map);

	return tmp;
}

/**
 *	get active thread object from map
 */
int thread_pool::get_active(pthread_t id, shared_thread& t) {
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
 *	clean up thread activity
 */
int thread_pool::clean(thread* t, bool& is_pool) {
	pthread_t id = t->get_id();
	int type = t->get_type();

	shared_thread tmp;
	pthread_rwlock_wrlock(&this->_mutex_global_map);
	log_debug("removing thread object from global map (type=%d, id=%d)", type, id);
	if (this->_global_map[type].count(id) == 0) {
		log_warning("specified id not found it global map (type=%d, id=%d)", type, id);
		is_pool = false;
		pthread_rwlock_unlock(&this->_mutex_global_map);
		return 0;
	}
	tmp = this->_global_map[type][id];
	this->_global_map[type].erase(id);
	pthread_rwlock_unlock(&this->_mutex_global_map);

	pthread_rwlock_wrlock(&this->_mutex_pool);
	if (this->_pool.size() < this->get_max_pool_size()) {
		log_debug("adding thread object to pool (id=%d)", id);
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
			this->_global_map[it->first].erase(it_local->first);
		}
		this->_global_map.erase(it->first);
	}
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
	t->startup(weak_t);

	return t;
}
// }}}

// {{{ private methods
// }}}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
