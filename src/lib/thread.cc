/**
 *	thread.cc
 *
 *	implementation of gree::flare::thread
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "thread.h"
#include "thread_pool.h"
#include "thread_handler.h"

namespace gree {
namespace flare {

// {{{ global functions
void* thread_run(void* p) {
	thread* tmp = (thread*)p;
	shared_thread t = tmp->get_shared_thread();

	// signal mask
	sigset_t ss;
	sigfillset(&ss);
	sigdelset(&ss, SIGUSR1);
	if (pthread_sigmask(SIG_SETMASK, &ss, NULL) < 0) {
		log_err("pthread_sigmask() failed: %s (%d)", util::strerror(errno), errno);
	}

	bool is_pool = false;
	thread::shutdown_request r;
	do {
		try {
			t->wait();
			if ((r = t->is_shutdown_request())) {
				throw r;
			}

			t->run();
			if ((r = t->is_shutdown_request())) {
				throw r;
			}

			t->clean(is_pool);
			// we do not have to check if graceful or not here (thread::clean() clears shutdown request if graceful)
			if (t->is_shutdown_request()) {
				break;
			}
		} catch (thread::shutdown_request e) {
			if (e == thread::shutdown_request_graceful) {
				t->clean(is_pool);
			} else {
				break;
			}
		}
	} while (is_pool);

	t->notify_shutdown();

	return (void*)0;
}
// }}}

// {{{ ctor/dtor
/**
 *	ctor for thread
 */
thread::thread(thread_pool* t):
		_thread_pool(t),
		_id(0),
		_thread_id(0),
		_trigger(false),
		_shutdown(false),
		_shutdown_request(shutdown_request_none),
		_running(false),
		_thread_handler(NULL),
		_is_delete_thread_handler(false) {
	this->_info.id = 0;
	this->_info.thread_id = 0;
	this->_info.type = 0;
	this->_info.peer_name = "";
	this->_info.peer_port = 0;
	this->_info.op = "";
	this->_info.timestamp = 0;
	this->_info.state = "";
	this->_info.info = "";
	pthread_mutex_init(&this->_mutex_trigger, NULL);
	pthread_cond_init(&this->_cond_trigger, NULL);
	pthread_mutex_init(&this->_mutex_shutdown, NULL);
	pthread_cond_init(&this->_cond_shutdown, NULL);
}

/**
 *	dtor for thread
 */
thread::~thread() {
	if (this->_is_delete_thread_handler && this->_thread_handler != NULL) {
		log_debug("deleting thread_handler object", 0);
		_delete_(this->_thread_handler);
	}
	log_debug("thread is completely shutdown", 0);
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	preparing thread (creating thread and make it wait for signal)
 *
 *	(should be called from parent thread)
 */
int thread::startup(weak_thread myself) {
	this->_myself = myself;

	pthread_t thread_id;
	pthread_attr_t thr_attr;
	pthread_attr_init(&thr_attr);
	pthread_attr_setdetachstate(&thr_attr, PTHREAD_CREATE_DETACHED);
	if (pthread_create(&thread_id, &thr_attr, thread_run, (void*)this) < 0) {
		log_err("pthread_create() failed: %s", strerror(errno), errno);
		return -1;
	}
	this->_thread_id = thread_id;
	this->_info.thread_id = thread_id;

	log_debug("thread created (thread_id=%u)", this->_thread_id);

	return 0;
}

/**
 *	setup proc for each execution
 */
int thread::setup(int type, uint32_t id) {
	this->_id = id;

	this->_info.id = id;
	this->_info.type = type;
	this->_info.timestamp = time(NULL);
	this->_info.state = "setup";
	
	return 0;
}

/**
 *	wait for trigger
 *	
 *	(should be called from child thread)
 */
int thread::wait() {
	pthread_mutex_lock(&this->_mutex_trigger);
	if (this->_trigger) {
		log_info("trigger flag has been already set -> skip pthread_cond_wait()", 0);
	} else {
		log_debug("waiting for trigger signal", 0);
		pthread_cond_wait(&this->_cond_trigger, &this->_mutex_trigger);
	}
	this->_trigger = false;
	log_debug("trigger signal received", 0);
	pthread_mutex_unlock(&this->_mutex_trigger);

	return 0;
}

/**
 *	send a trigger signal
 *
 *	(should be called from parent thread)
 */
int thread::trigger(thread_handler* th, bool is_delete) {
	log_debug("sending trigger signal (thread_id=%u)", this->_thread_id);

	if (th != NULL) {
		this->_thread_handler = th;
		this->_is_delete_thread_handler = is_delete;
	}
	
	pthread_mutex_lock(&this->_mutex_trigger);
	// a fail safe flag in case we send signal before waiting
	this->_trigger = true;
	pthread_mutex_unlock(&this->_mutex_trigger);

	pthread_cond_signal(&this->_cond_trigger);

	return 0;
}

/**
 *	run thread w/ specified method
 *
 *	(should be called from child thread)
 */
int thread::run() {
	if (this->_thread_handler == NULL) {
		log_warning("thread handler object is not set -> skip running", 0);
		return -1;
	}

	this->_running = true;
	log_debug("setting running flag=%d", this->_running);

	this->_thread_handler->run();

	this->_running = false;
	log_debug("setting running flag=%d", this->_running);

	if (this->_is_delete_thread_handler && this->_thread_handler != NULL) {
		log_debug("deleting thread_handler object", 0);
		_delete_(this->_thread_handler);
	}
	this->_thread_handler = NULL;
	this->_is_delete_thread_handler = false;

	return 0;
}

/**
 *	clean up *current* thread activity
 */
int thread::clean(bool& is_pool) {
	this->_trigger = false;
	if (this->_shutdown_request == shutdown_request_graceful) {
		this->_shutdown_request = shutdown_request_none;
	}

	int r = this->_thread_pool->clean(this, is_pool);

	// we should clean id *after* we clean up thread pool issue
	this->_id = 0;

	this->_info.id = 0;
	this->_info.type = 0;
	this->_info.peer_name = "";
	this->_info.peer_port = 0;
	this->_info.op = "";
	this->_info.timestamp = 0;
	this->_info.state = "";
	this->_info.info = "";

	return r;
}

/**
 *	shutdown thread
 */
int thread::shutdown(bool graceful, bool async) {
	log_info("shutting down thread (thread_id=%u, running=%d, graceful=%d, async=%d)", this->_thread_id, this->_running, graceful, async);

	this->_shutdown_request = graceful ? shutdown_request_graceful : shutdown_request_force;
	this->trigger(NULL);

	if (this->_running) {
		log_debug("sending SIGUSR1 to %u", this->_thread_id);
		pthread_kill(this->_thread_id, SIGUSR1);
	}

	if (async) {
		log_info("asynchronous shutdown request -> skip waiting", 0);
		return 0;
	}

	pthread_mutex_lock(&this->_mutex_shutdown);
	if (this->_shutdown) {
		// shutdown flag is already set -> skip waiting
		log_debug("thread is now exiting -> skip waiting", 0);
	} else {
		log_debug("waiting for thread to exit (thread_id=%u, timeout=%d)", this->_thread_id, thread::shutdown_timeout);
		struct timeval now;
		struct timespec timeout;
		gettimeofday(&now, NULL);
		timeout.tv_sec = now.tv_sec + thread::shutdown_timeout;
		timeout.tv_nsec = now.tv_usec * 1000;
		int r = pthread_cond_timedwait(&this->_cond_shutdown, &this->_mutex_shutdown, &timeout);
		if (r == ETIMEDOUT) {
			log_warning("thread shutdown timeout (thread_id=%u, timeout=%d)", this->_thread_id, thread::shutdown_timeout);
		} else {
			log_debug("thread seems to be exiting (thread_id=%u)", this->_thread_id);
		}
	}
	pthread_mutex_unlock(&this->_mutex_shutdown);

	return 0;
}

/**
 *	notify current thread is shutting down
 */
int thread::notify_shutdown() {
	log_debug("thread is shutting down (thread_id=%u)", this->_thread_id);
	pthread_mutex_lock(&this->_mutex_shutdown);
	this->_shutdown = true;
	pthread_mutex_unlock(&this->_mutex_shutdown);

	pthread_cond_signal(&this->_cond_shutdown);

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
