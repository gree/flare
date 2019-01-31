/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
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
		_get_hits(0),
		_get_misses(0),
		_delete_hits(0),
		_delete_misses(0),
		_incr_hits(0),
		_incr_misses(0),
		_decr_hits(0),
		_decr_misses(0),
		_cas_hits(0),
		_cas_misses(0),
		_cas_badval(0),
		_touch_hits(0),
		_touch_misses(0),
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

uint32_t stats::get_total_items() {
	return this->_total_items.fetch();
}

uint64_t stats::get_bytes(storage* st) {
	return st ? st->size() : 0;
}

uint32_t stats::get_curr_connections(thread_pool* req_tp, thread_pool* other_tp) {
	return 0;
}

uint32_t stats::get_total_connections()						{return this->_total_connections.fetch();}
uint32_t stats::get_connection_structures()				{return 0;}

uint64_t stats::get_cmd_get()											{ return this->_cmd_get.fetch(); }
uint64_t stats::get_cmd_set()											{ return this->_cmd_set.fetch(); }
uint64_t stats::get_get_hits()											{ return this->_get_hits.fetch(); }
uint64_t stats::get_get_misses()										{ return this->_get_misses.fetch(); }
uint64_t stats::get_delete_hits()									{ return this->_delete_hits.fetch(); }
uint64_t stats::get_delete_misses()								{ return this->_delete_misses.fetch(); }
uint64_t stats::get_incr_hits()										{ return this->_incr_hits.fetch(); }
uint64_t stats::get_incr_misses()									{ return this->_incr_misses.fetch(); }
uint64_t stats::get_decr_hits()										{ return this->_decr_hits.fetch(); }
uint64_t stats::get_decr_misses()									{ return this->_decr_misses.fetch(); }
uint64_t stats::get_cas_hits()											{ return this->_cas_hits.fetch(); }
uint64_t stats::get_cas_misses()										{ return this->_cas_misses.fetch(); }
uint64_t stats::get_cas_badval()										{ return this->_cas_badval.fetch(); }
uint64_t stats::get_touch_hits()										{ return this->_touch_hits.fetch(); }
uint64_t stats::get_touch_misses()									{ return this->_touch_misses.fetch(); }
uint64_t stats::get_evictions()										{ return 0; }
uint64_t stats::get_bytes_read()										{ return this->_bytes_read.fetch();}
uint64_t stats::get_bytes_written()								{ return this->_bytes_written.fetch();}

uint32_t stats::get_total_thread_queue()						{ return this->_total_thread_queue.fetch();}
uint32_t stats::get_limit_maxbytes()								{ return 0; }
uint32_t stats::get_threads(thread_pool* req_th, thread_pool* other_th)				{ return req_th->get_thread_size() + other_th->get_thread_size(); }
uint32_t stats::get_pool_threads(thread_pool* req_th, thread_pool* other_th)	{ return req_th->get_pool_size(); }

// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
