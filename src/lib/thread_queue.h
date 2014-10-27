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

using namespace std;

namespace gree {
namespace flare {

typedef class thread_queue thread_queue;
typedef boost::shared_ptr<thread_queue> shared_thread_queue;

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
