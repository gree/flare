/**
 *	thread_queue.cc
 *
 *	implementation of gree::flare::thread_queue
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "thread_queue.h"
#include "app.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for thread_queue
 */
thread_queue::thread_queue():
		_ident(""),
		_sync(false),
		_sync_ref_count(0),
		_success(false) {
	pthread_mutex_init(&this->_mutex_sync, NULL);
	pthread_cond_init(&this->_cond_sync, NULL);
	this->_timestamp = stats_object->get_timestamp();
}

/**
 *	ctor for thread_queue
 */
thread_queue::thread_queue(string ident):
		_ident(ident),
		_sync(false),
		_sync_ref_count(0),
		_success(false) {
	pthread_mutex_init(&this->_mutex_sync, NULL);
	pthread_cond_init(&this->_cond_sync, NULL);
	this->_timestamp = stats_object->get_timestamp();
}

/**
 *	dtor for thread_queue
 */
thread_queue::~thread_queue() {
	pthread_mutex_destroy(&this->_mutex_sync);
	pthread_cond_destroy(&this->_cond_sync);
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int thread_queue::run(shared_connection c) {
	this->_success = true;

	return 0;
}

/**
 *	wait for queue process
 */
int thread_queue::sync() {
	if (this->_sync == false) {
		return 0;
	}

	pthread_mutex_lock(&this->_mutex_sync);
	log_debug("waiting for sync signal... (current ref count = %d)", this->_sync_ref_count);
	if (this->_sync_ref_count == 0) {
		log_debug("sync ref count is already 0 -> skip waiting", 0);
	} else {
		pthread_cond_wait(&this->_cond_sync, &this->_mutex_sync);
		log_debug("sync signal received", 0);
	}
	pthread_mutex_unlock(&this->_mutex_sync);

	return 0;
}

/**
 *	add sync ref count
 */
int thread_queue::sync_ref() {
	this->_sync = true;

	pthread_mutex_lock(&this->_mutex_sync);
	this->_sync_ref_count++;
	log_debug("sync ref count++ (%d)", this->_sync_ref_count);
	pthread_mutex_unlock(&this->_mutex_sync);

	return 0;
}

/**
 *	remove sync ref count
 */
int thread_queue::sync_unref() {
	if (this->_sync == false) {
		return 0;
	}

	volatile bool flag;
	pthread_mutex_lock(&this->_mutex_sync);
	this->_sync_ref_count--;
	flag = this->_sync_ref_count == 0 ? true : false;
	log_debug("sync ref count-- (%d)%s", this->_sync_ref_count, this->_sync_ref_count == 0 ? " (-> sending signal)" : "");
	pthread_mutex_unlock(&this->_mutex_sync);

	if (flag) {
		pthread_cond_signal(&this->_cond_sync);
	}

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
