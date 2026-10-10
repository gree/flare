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
 *	thread.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	THREAD_H
#define	THREAD_H

#include <map>
#include <queue>

#include <boost/shared_ptr.hpp>
#include <boost/weak_ptr.hpp>

#include <pthread.h>
#include <signal.h>
#include <sys/time.h>
#include <time.h>

#include "logger.h"
#include "util.h"
#include "thread_queue.h"

namespace gree {
namespace flare {

class thread;
typedef boost::shared_ptr<gree::flare::thread>		shared_thread;
typedef boost::weak_ptr<gree::flare::thread>		weak_thread;

class thread_pool;
class thread_handler;

/**
 *	thread class
 */
class thread {
public:
	typedef struct				_thread_info {
		unsigned int				id;
		pthread_t						thread_id;
		int									type;
		string							peer_name;
		int									peer_port;
		string							op;
		time_t							timestamp;
		string							state;
		string							info;
		uint32_t						queue_size;
		int									queue_behind;
	} thread_info;

	enum									shutdown_request {
		shutdown_request_none = 0,
		shutdown_request_graceful,
		shutdown_request_force,
	};

	static const int			shutdown_timeout = 60;			// sec

private:
	thread_pool*					_thread_pool;
	weak_thread						_myself;

	unsigned int					_id;
	pthread_t							_thread_id;
	thread_info						_info;

	pthread_mutex_t				_mutex_trigger;
	pthread_cond_t				_cond_trigger;
	bool									_trigger;

	pthread_mutex_t				_mutex_shutdown;
	pthread_cond_t				_cond_shutdown;
	bool									_shutdown;
	shutdown_request			_shutdown_request;

	pthread_mutex_t				_mutex_running;
	pthread_cond_t				_cond_running;
	bool									_running;

	thread_handler*				_thread_handler;
	bool									_is_delete_thread_handler;

	queue<shared_thread_queue>	_thread_queue;
	pthread_mutex_t							_mutex_queue;
	pthread_cond_t							_cond_queue;

	pthread_rwlock_t			_mutex_info;

public:
	thread(thread_pool* t);
	virtual ~thread();

	int startup(weak_thread myself, int stack_size);
	int setup(int type, unsigned int id);
	int trigger(thread_handler* th, bool request_delete = true, bool async = true);
	int wait();
	int run();
	int clean(bool& is_pool);
	int clean_internal();
	int shutdown(bool graceful = false, bool async = false);
	int notify_shutdown();

	int dequeue(shared_thread_queue& q, int timeout);
	int enqueue(shared_thread_queue& q, uint32_t max_total_thread_queue = 0);
	thread_info get_thread_info();

	bool is_myself() { return pthread_self() == this->_thread_id; };
	unsigned int get_id() { return this->_id; };
	pthread_t get_thread_id() { return this->_thread_id; };
	int get_type() { return this->_info.type; };
	int set_peer(string host, int port) { pthread_rwlock_wrlock(&this->_mutex_info); this->_info.peer_name = host; this->_info.peer_port = port; pthread_rwlock_unlock(&this->_mutex_info); return 0; };
	int set_op(string op) { pthread_rwlock_wrlock(&this->_mutex_info); this->_info.op = op; pthread_rwlock_unlock(&this->_mutex_info); return 0; };
	string get_state() { pthread_rwlock_rdlock(&this->_mutex_info); string s = this->_info.state; pthread_rwlock_unlock(&this->_mutex_info); return s; };
	int set_state(string state) { pthread_rwlock_wrlock(&this->_mutex_info); log_debug("%s -> %s", this->_info.state.c_str(), state.c_str()); this->_info.state = state; pthread_rwlock_unlock(&this->_mutex_info); return 0; };
	bool is_running() { return this->_running; };
	shutdown_request is_shutdown_request() { return this->_shutdown_request; };
	shared_thread get_shared_thread() { return this->_myself.lock(); };

protected:
};

}	// namespace flare
}	// namespace gree

#endif	// THREAD_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
