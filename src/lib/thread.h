/**
 *	thread.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__THREAD_H__
#define	__THREAD_H__

#include <map>
#include <vector>

#include <boost/shared_ptr.hpp>
#include <boost/weak_ptr.hpp>

#include <pthread.h>
#include <signal.h>
#include <sys/time.h>
#include <time.h>

#include "logger.h"
#include "mm.h"
#include "util.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

typedef class thread					thread;
typedef shared_ptr<thread>		shared_thread;
typedef weak_ptr<thread>			weak_thread;

typedef class thread_pool			thread_pool;
typedef class thread_handler	thread_handler;

/**
 *	thread class
 */
class thread {
public:
	typedef struct				_thread_info {
		pthread_t						id;
		int									type;
		string							peer_name;
		int									peer_port;
		string							op;
		time_t							timestamp;
		string							state;
		string							info;
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

	pthread_t							_id;
	thread_info						_info;

	pthread_mutex_t				_mutex_trigger;
	pthread_cond_t				_cond_trigger;
	bool									_trigger;

	pthread_mutex_t				_mutex_shutdown;
	pthread_cond_t				_cond_shutdown;
	bool									_shutdown;
	shutdown_request			_shutdown_request;

	bool									_running;

	thread_handler*				_thread_handler;
	bool									_is_delete_thread_handler;

public:
	thread(thread_pool* t);
	virtual ~thread();

	int startup(weak_thread myself);
	int setup(int type);
	int trigger(thread_handler* th, bool is_delete = true);
	int wait();
	int run();
	int clean(bool& is_pool);
	int shutdown(bool graceful = false, bool async = false);
	int notify_shutdown();

	pthread_t get_id() { return this->_id; };
	int get_type() { return this->_info.type; };
	int set_peer(string host, int port) { this->_info.peer_name = host; this->_info.peer_port = port; return 0; };
	int set_op(string op) { this->_info.op = op; return 0; };
	string get_state() { return this->_info.state; };
	int set_state(string state) { log_debug("%s -> %s", this->_info.state.c_str(), state.c_str()); this->_info.state = state; return 0; };
	int set_info(string info) { this->_info.info = info; return 0; };
	thread_info get_thread_info() { return this->_info; };
	bool is_running() { return this->_running; };
	shutdown_request is_shutdown_request() { return this->_shutdown_request; };
	shared_thread get_shared_thread() { return this->_myself.lock(); };

protected:
};

}	// namespace flare
}	// namespace gree

#endif	// __THREAD_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
