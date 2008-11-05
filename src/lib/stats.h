/**
 *	stats.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__STATS_H__
#define	__STATS_H__

#include <boost/lexical_cast.hpp>

#include <sys/resource.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "config.h"
#include "thread_pool.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	stats class
 */
class stats {
protected:
	time_t			_start_timestamp;
	time_t			_current_timestamp;
	uint32_t		_total_connections;
	uint32_t		_cmd_get;
	uint32_t		_cmd_set;
	uint32_t		_hits;
	uint32_t		_misses;
	uint32_t		_bytes_read;
	uint32_t		_bytes_written;

public:
	stats();
	virtual ~stats();

	int startup();

	inline int increment_total_connections() { uint32_t dummy; ATOMIC_ADD(&this->_total_connections, 1, dummy); return 0; };
	inline int increment_cmd_get() { uint32_t dummy; ATOMIC_ADD(&this->_cmd_get, 1, dummy); return 0; };
	inline int increment_cmd_set() { uint32_t dummy; ATOMIC_ADD(&this->_cmd_set, 1, dummy); return 0; };
	inline int increment_hits() { uint32_t dummy; ATOMIC_ADD(&this->_hits, 1, dummy); return 0; };
	inline int increment_misses() { uint32_t dummy; ATOMIC_ADD(&this->_misses, 1, dummy); return 0; };
	inline int add_bytes_read(uint32_t n) { uint32_t dummy; ATOMIC_ADD(&this->_bytes_read, n, dummy); return 0; };
	inline int add_bytes_written(uint32_t n) { uint32_t dummy; ATOMIC_ADD(&this->_bytes_written, n, dummy); return 0; };

	pid_t get_pid();
	time_t get_uptime();
	time_t get_timestamp();
	int update_timestamp(time_t t = 0);
	const char* get_version();
	int get_pointer_size();
	struct rusage get_rusage();
	virtual uint32_t get_curr_items();
	virtual uint32_t get_total_items();
	virtual uint32_t get_bytes();
	virtual uint32_t get_curr_connections(thread_pool* tp);
	uint32_t get_total_connections();
	uint32_t get_connection_structures();
	uint64_t get_cmd_get();
	uint64_t get_cmd_set();
	uint64_t get_hits();
	uint64_t get_misses();
	uint64_t get_evictions();
	uint64_t get_bytes_read();
	uint64_t get_bytes_written();
	uint32_t get_limit_maxbytes();
	uint32_t get_threads(thread_pool* tp);
	uint32_t get_pool_threads(thread_pool* tp);
};

}	// namespace flare
}	// namespace gree

#endif	// __STATS_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
