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

namespace gree {
namespace flare {

/**
 *	stats class
 */
class stats {
protected:
	time_t			_start_timestamp;
	time_t			_current_timestamp;
	AtomicCounter _total_items;
	AtomicCounter _total_connections;
	AtomicCounter _cmd_get;
	AtomicCounter _cmd_set;
	AtomicCounter _get_hits;
	AtomicCounter _get_misses;
	AtomicCounter _delete_hits;
	AtomicCounter _delete_misses;
	AtomicCounter _incr_hits;
	AtomicCounter _incr_misses;
	AtomicCounter _decr_hits;
	AtomicCounter _decr_misses;
	AtomicCounter _cas_hits;
	AtomicCounter _cas_misses;
	AtomicCounter _cas_badval;
	AtomicCounter _touch_hits;
	AtomicCounter _touch_misses;
	AtomicCounter _bytes_read;
	AtomicCounter _bytes_written;
	AtomicCounter _total_thread_queue;

public:
	stats();
	virtual ~stats();

	int startup();

	inline int increment_total_items()           { this->_total_items.incr();return 0; };
	inline int increment_total_connections()     { this->_total_connections.incr();return 0; };
	inline int increment_cmd_get()               { this->_cmd_get.incr();return 0; };
	inline int increment_cmd_set()               { this->_cmd_set.incr();return 0; };
	inline int increment_get_hits()              { this->_get_hits.incr();return 0; };
	inline int increment_get_misses()            { this->_get_misses.incr();return 0; };
	inline int increment_delete_hits()           { this->_delete_hits.incr();return 0; };
	inline int increment_delete_misses()         { this->_delete_misses.incr();return 0; };
	inline int increment_incr_hits()             { this->_incr_hits.incr();return 0; };
	inline int increment_incr_misses()           { this->_incr_misses.incr();return 0; };
	inline int increment_decr_hits()             { this->_decr_hits.incr();return 0; };
	inline int increment_decr_misses()           { this->_decr_misses.incr();return 0; };
	inline int increment_cas_hits()              { this->_cas_hits.incr();return 0; };
	inline int increment_cas_misses()            { this->_cas_misses.incr();return 0; };
	inline int increment_cas_badval()            { this->_cas_badval.incr();return 0; };
	inline int increment_touch_hits()            { this->_touch_hits.incr();return 0; };
	inline int increment_touch_misses()          { this->_touch_misses.incr();return 0; };
	inline int add_bytes_read(uint64_t n)        { this->_bytes_read.add(n);return 0; };
	inline int add_bytes_written(uint64_t n)     { this->_bytes_written.add(n);return 0; };
	inline int increment_total_thread_queue()    { this->_total_thread_queue.incr();return 0; };
	inline int decrement_total_thread_queue()    { this->_total_thread_queue.add(-1);return 0; };

	pid_t get_pid();
	time_t get_uptime();
	time_t get_timestamp();
	int update_timestamp(time_t t = 0);
	const char* get_version();
	int get_pointer_size();
	struct rusage get_rusage();
	virtual uint32_t get_curr_items(storage* st);
	virtual uint32_t get_total_items();
	virtual uint64_t get_bytes(storage* st);
	virtual uint32_t get_curr_connections(thread_pool* tp);
	uint32_t get_total_connections();
	uint32_t get_connection_structures();
	uint64_t get_cmd_get();
	uint64_t get_cmd_set();
	uint64_t get_get_hits();
	uint64_t get_get_misses();
	uint64_t get_delete_hits();
	uint64_t get_delete_misses();
	uint64_t get_incr_hits();
	uint64_t get_incr_misses();
	uint64_t get_decr_hits();
	uint64_t get_decr_misses();
	uint64_t get_cas_hits();
	uint64_t get_cas_misses();
	uint64_t get_cas_badval();
	uint64_t get_touch_hits();
	uint64_t get_touch_misses();
	uint64_t get_evictions();
	uint64_t get_bytes_read();
	uint64_t get_bytes_written();
	uint32_t get_total_thread_queue();
	uint32_t get_limit_maxbytes();
	uint32_t get_threads(thread_pool* tp);
	uint32_t get_pool_threads(thread_pool* tp);
};

}	// namespace flare
}	// namespace gree

#endif	// STATS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
