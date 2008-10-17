/**
 *	thread_pool.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__THREAD_POOL_H__
#define	__THREAD_POOL_H__

#include <map>
#include <stack>
#include <vector>

#include "thread.h"
#include "thread_handler.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	thread pooling class
 */
class thread_pool {
public:
	enum							thread_type {
		thread_type_request = 1,
	};

	typedef	map<uint32_t, shared_thread>		local_map;
	typedef	map<int, local_map>							global_map;
	typedef	stack<shared_thread>						pool;

protected:
	uint32_t					_index;
	global_map				_global_map;
	pool							_pool;

	pthread_rwlock_t	_mutex_global_map;
	pthread_rwlock_t	_mutex_pool;

	pool::size_type		_max_pool_size;

public:
	thread_pool(pool::size_type max_pool_size);
	virtual ~thread_pool();

	shared_thread get(int type);
	int get_active(uint32_t id, shared_thread& t);
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

#endif	// __THREAD_POOL_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
