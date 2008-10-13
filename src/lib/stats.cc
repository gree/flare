/**
 *	stats.cc
 *
 *	implementation of gree::flare::stats
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "stats.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for stats
 */
stats::stats():
		_timestamp(0),
		_total_connections(0),
		_cmd_get(0),
		_cmd_set(0),
		_hits(0),
		_misses(0),
		_bytes_read(0),
		_bytes_written(0) {
}

/**
 *	dtor for stats
 */
stats::~stats() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	startup procs
 */
int stats::startup() {
	this->_timestamp = time(NULL);

	return 0;
}

/**
 *	get current pid
 */
pid_t stats::get_pid() {
	return getpid();
}

/**
 *	get process uptime
 */
time_t stats::get_uptime() {
	return time(NULL) - this->_timestamp;
}

/**
 *	get current timestamp
 */
time_t stats::get_timestamp() {
	return time(NULL);
}

const char* stats::get_version() {
	return PACKAGE_VERSION;
}

int stats::get_pointer_size() {
	return sizeof(void*) * 8;
}

struct rusage stats::get_rusage() {
	rusage usage;
	getrusage(RUSAGE_SELF, &usage);

	return usage;
}

uint32_t stats::get_curr_items() {
	return 0;
}

uint32_t stats::get_total_items() {
	return 0;
}

uint32_t stats::get_bytes() {
	return 0;
}

uint32_t stats::get_curr_connections(thread_pool* tp) {
	return 0;
}

uint32_t stats::get_total_connections() {
	return this->_total_connections;
}

uint32_t stats::get_connection_structures() {
	return 0;
}

uint64_t stats::get_cmd_get() {
	return this->_cmd_get;
}

uint64_t stats::get_cmd_set() {
	return this->_cmd_set;
}

uint64_t stats::get_hits() {
	return this->_hits;
}

uint64_t stats::get_misses() {
	return this->_misses;
}

uint64_t stats::get_evictions() {
	return 0;
}

uint64_t stats::get_bytes_read() {
	return this->_bytes_read;
}

uint64_t stats::get_bytes_written() {
	return this->_bytes_written;
}

uint32_t stats::get_limit_maxbytes() {
	return 0;
}

uint32_t stats::get_threads(thread_pool* th) {
	return th->get_thread_size();
}

uint32_t stats::get_pool_threads(thread_pool* th) {
	return th->get_pool_size();
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
