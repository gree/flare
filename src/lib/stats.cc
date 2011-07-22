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
		_start_timestamp(0),
		_current_timestamp(0),
		_total_items(0),
		_total_connections(0),
		_cmd_get(0),
		_cmd_set(0),
		_hits(0),
		_misses(0),
		_bytes_read(0),
		_bytes_written(0),
		_total_thread_queue(0) {
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
	this->_start_timestamp = time(NULL);

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
	return this->_current_timestamp - this->_start_timestamp;
}

/**
 *	get current timestamp
 */
time_t stats::get_timestamp() {
	return this->_current_timestamp;
}

/**
 *	update current timestamp
 */
int stats::update_timestamp(time_t t) {
	if (t == 0) {
		this->_current_timestamp = time(NULL);
	} else {
		this->_current_timestamp = t;
	}
	return 0;
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

uint32_t stats::get_curr_items(storage* st) {
	return st ? st->count() : 0;
}

unsigned int stats::get_total_items() {
	return this->_total_items;
}

uint64_t stats::get_bytes(storage* st) {
	return st ? st->size() : 0;
}

uint32_t stats::get_curr_connections(thread_pool* tp) {
	return 0;
}

unsigned int stats::get_total_connections() {
	return this->_total_connections;
}

uint32_t stats::get_connection_structures() {
	return 0;
}

unsigned int stats::get_cmd_get() {
	return this->_cmd_get;
}

unsigned int stats::get_cmd_set() {
	return this->_cmd_set;
}

unsigned int stats::get_hits() {
	return this->_hits;
}

unsigned int stats::get_misses() {
	return this->_misses;
}

unsigned int stats::get_evictions() {
	return 0;
}

unsigned int stats::get_bytes_read() {
	return this->_bytes_read;
}

unsigned int stats::get_bytes_written() {
	return this->_bytes_written;
}

unsigned int stats::get_total_thread_queue() {
	return this->_total_thread_queue;
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
