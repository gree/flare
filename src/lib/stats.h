/**
 *	stats.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	STATS_H
#define	STATS_H

#include <boost/lexical_cast.hpp>

#include <sys/resource.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "config.h"
#include "storage.h"
#include "thread_pool.h"

using namespace std;
using namespace boost;

#ifdef HAVE_BOOST_ATOMIC
#include <boost/atomic.hpp>
#define UINT_D boost::atomic<uint64_t>
#define UINT_T uint64_t
#define UINT_T_ATOMIC_ADD(val)  {(val).fetch_add(1, boost::memory_order_relaxed);}
#else
#define UINT_T uint32_t 
#define UINT_T_ATOMIC_ADD(val)  {unsigned int dummy; ATOMIC_ADD(&(val), 1, dummy);}
#endif


namespace gree {
namespace flare {

/**
 *	stats class
 */
class stats {
protected:
	time_t				_start_timestamp;
	time_t				_current_timestamp;
	unsigned int	_total_items;
	unsigned int	_total_connections;
	UINT_D	        _cmd_get;
	UINT_D	        _cmd_set;
	UINT_D	        _get_hits;
	UINT_D	        _get_misses;
	UINT_D	        _delete_hits;
	UINT_D	        _delete_misses;
	UINT_D	        _incr_hits;
	UINT_D	        _incr_misses;
	UINT_D	        _decr_hits;
	UINT_D	        _decr_misses;
	UINT_D	        _cas_hits;
	UINT_D	        _cas_misses;
	UINT_D	        _cas_badval;
	UINT_D	        _touch_hits;
	UINT_D	        _touch_misses;
	unsigned int	_bytes_read;
	unsigned int	_bytes_written;
	unsigned int	_total_thread_queue;

public:
	stats();
	virtual ~stats();

	int startup();

	inline int increment_total_items() { unsigned int dummy; ATOMIC_ADD(&this->_total_items, 1, dummy); return 0; };
	inline int increment_total_connections() { unsigned int dummy; ATOMIC_ADD(&this->_total_connections, 1, dummy); return 0; };
	inline int increment_cmd_get()		{ UINT_T_ATOMIC_ADD(this->_cmd_get);return 0; };
	inline int increment_cmd_set()		{ UINT_T_ATOMIC_ADD(this->_cmd_set);return 0; };
	inline int increment_get_hits()		{ UINT_T_ATOMIC_ADD(this->_get_hits);return 0; };
	inline int increment_get_misses()	{ UINT_T_ATOMIC_ADD(this->_get_misses);return 0; };
	inline int increment_delete_hits()	{ UINT_T_ATOMIC_ADD(this->_delete_hits);return 0; };
	inline int increment_delete_misses()	{ UINT_T_ATOMIC_ADD(this->_delete_misses);return 0; };
	inline int increment_incr_hits()	{ UINT_T_ATOMIC_ADD(this->_incr_hits);return 0; };
	inline int increment_incr_misses()	{ UINT_T_ATOMIC_ADD(this->_incr_misses);return 0; };
	inline int increment_decr_hits()	{ UINT_T_ATOMIC_ADD(this->_decr_hits);return 0; };
	inline int increment_decr_misses()	{ UINT_T_ATOMIC_ADD(this->_decr_misses);return 0; };
	inline int increment_cas_hits()		{ UINT_T_ATOMIC_ADD(this->_cas_hits);return 0; };
	inline int increment_cas_misses()	{ UINT_T_ATOMIC_ADD(this->_cas_misses);return 0; };
	inline int increment_cas_badval()	{ UINT_T_ATOMIC_ADD(this->_cas_badval);return 0; };
	inline int increment_touch_hits()	{ UINT_T_ATOMIC_ADD(this->_touch_hits);return 0; };
	inline int increment_touch_misses()	{ UINT_T_ATOMIC_ADD(this->_touch_misses);return 0; };
	
	inline int add_bytes_read(unsigned int n) { unsigned int dummy; ATOMIC_ADD(&this->_bytes_read, n, dummy); return 0; };
	inline int add_bytes_written(unsigned int n) { unsigned int dummy; ATOMIC_ADD(&this->_bytes_written, n, dummy); return 0; };
	inline int increment_total_thread_queue() { unsigned int dummy; ATOMIC_ADD(&this->_total_thread_queue, 1, dummy); return 0; };
	inline int decrement_total_thread_queue() { unsigned int dummy; ATOMIC_ADD(&this->_total_thread_queue, -1, dummy); return 0; };

	pid_t get_pid();
	time_t get_uptime();
	time_t get_timestamp();
	int update_timestamp(time_t t = 0);
	const char* get_version();
	int get_pointer_size();
	struct rusage get_rusage();
	virtual uint32_t get_curr_items(storage* st);
	virtual unsigned int get_total_items();
	virtual uint64_t get_bytes(storage* st);
	virtual uint32_t get_curr_connections(thread_pool* tp);
	unsigned int get_total_connections();
	uint32_t get_connection_structures();
	UINT_T get_cmd_get();
	UINT_T get_cmd_set();
	UINT_T get_get_hits();
	UINT_T get_get_misses();
	UINT_T get_delete_hits();
	UINT_T get_delete_misses();
	UINT_T get_incr_hits();
	UINT_T get_incr_misses();
	UINT_T get_decr_hits();
	UINT_T get_decr_misses();
	UINT_T get_cas_hits();
	UINT_T get_cas_misses();
	UINT_T get_cas_badval();
	UINT_T get_touch_hits();
	UINT_T get_touch_misses();
	unsigned int get_evictions();
	unsigned int get_bytes_read();
	unsigned int get_bytes_written();
	unsigned int get_total_thread_queue();
	uint32_t get_limit_maxbytes();
	uint32_t get_threads(thread_pool* tp);
	uint32_t get_pool_threads(thread_pool* tp);
};

}	// namespace flare
}	// namespace gree

#endif	// STATS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
