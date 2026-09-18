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
#include <stdlib.h>

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
		_proxy_write_dropped(0),
		_reconstruction_started(0),
		_reconstruction_completed(0),
		_reconstruction_failed(0),
		_follow_state(follow_idle),
		_follow_applied_lsn(0),
		_follow_source_lsn(0),
		_follow_source_lsn_observed_at(0),
		_follow_last_progress_at(0),
		_reconstruction_boot_id(0),
		_reconstruction_current_id(0),
		_reconstruction_current_state(0),
		_reconstruction_last_success_id(0),
		_reconstruction_last_success_source(""),
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
	pthread_mutex_init(&this->_mutex_proxy_write_dropped_by_dest, NULL);
	pthread_mutex_init(&this->_mutex_reconstruction, NULL);
	pthread_mutex_init(&this->_mutex_follow, NULL);
	// Random per process; combined with time so two processes started in the
	// same second still differ. Never persisted.
	{
		uint64_t r = (uint64_t)time(NULL) << 32;
		r ^= ((uint64_t)getpid() << 16) ^ (uint64_t)random();
		if (r == 0) r = 1;
		this->_reconstruction_boot_id = r;
	}
}

/**
 *	dtor for stats
 */
stats::~stats() {
	pthread_mutex_destroy(&this->_mutex_proxy_write_dropped_by_dest);
	pthread_mutex_destroy(&this->_mutex_reconstruction);
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
uint64_t stats::get_proxy_write_dropped()					{ return this->_proxy_write_dropped.fetch(); }
uint64_t stats::get_reconstruction_started()			{ return this->_reconstruction_started.fetch(); }

static const char* _reconstruction_state_name(int s) {
	switch (s) {
	case stats::reconstruction_running: return "running";
	case stats::reconstruction_succeeded: return "succeeded";
	case stats::reconstruction_failed_state: return "failed";
	case stats::reconstruction_aborted: return "aborted";
	default: return "none";
	}
}

uint64_t stats::reconstruction_begin() {
	pthread_mutex_lock(&this->_mutex_reconstruction);
	this->_reconstruction_started.incr();
	this->_reconstruction_current_id = this->_reconstruction_started.fetch();
	this->_reconstruction_current_state = reconstruction_running;
	uint64_t id = this->_reconstruction_current_id;
	pthread_mutex_unlock(&this->_mutex_reconstruction);
	return id;
}
int stats::reconstruction_succeeded_from(uint64_t id, const string& source) {
	this->_reconstruction_completed.incr();
	pthread_mutex_lock(&this->_mutex_reconstruction);
	// last_success only ADVANCES: a late success of an older handler never
	// masks a newer one, and never claims the newer id.
	if (id > this->_reconstruction_last_success_id) {
		this->_reconstruction_last_success_id = id;
		this->_reconstruction_last_success_source = source;
	}
	// The current state belongs to the CURRENT handler only.
	if (id == this->_reconstruction_current_id) {
		this->_reconstruction_current_state = reconstruction_succeeded;
	}
	pthread_mutex_unlock(&this->_mutex_reconstruction);
	return 0;
}
int stats::reconstruction_failed_final(uint64_t id) {
	this->_reconstruction_failed.incr();
	pthread_mutex_lock(&this->_mutex_reconstruction);
	if (id == this->_reconstruction_current_id) {
		this->_reconstruction_current_state = reconstruction_failed_state;
	}
	pthread_mutex_unlock(&this->_mutex_reconstruction);
	return 0;
}
int stats::reconstruction_aborted_by_shutdown(uint64_t id) {
	pthread_mutex_lock(&this->_mutex_reconstruction);
	if (id == this->_reconstruction_current_id) {
		this->_reconstruction_current_state = reconstruction_aborted;
	}
	pthread_mutex_unlock(&this->_mutex_reconstruction);
	return 0;
}
namespace {
	const char* _follow_state_name(int st) {
		switch (st) {
			case stats::follow_initial_sync:  return "initial_sync";
			case stats::follow_following:     return "following";
			case stats::follow_disconnected:  return "disconnected";
			case stats::follow_needs_rebuild: return "needs_rebuild";
			case stats::follow_error:         return "error";
			default:                          return "idle";
		}
	}
}

stats::follow_record stats::get_follow_record() {
	follow_record r;
	pthread_mutex_lock(&this->_mutex_follow);
	r.source = this->_follow_source;
	r.source_epoch = this->_follow_source_epoch;
	r.state = _follow_state_name(this->_follow_state);
	r.last_reason = this->_follow_last_reason;
	r.applied_lsn = this->_follow_applied_lsn;
	r.source_lsn = this->_follow_source_lsn;
	r.source_lsn_observed_at = this->_follow_source_lsn_observed_at;
	r.last_progress_at = this->_follow_last_progress_at;
	pthread_mutex_unlock(&this->_mutex_follow);
	return r;
}

int stats::follow_set_state(follow_state st, const string& reason) {
	pthread_mutex_lock(&this->_mutex_follow);
	const bool changed = (this->_follow_state != static_cast<int>(st));
	this->_follow_state = st;
	if (!reason.empty() || st == follow_following || st == follow_idle) {
		this->_follow_last_reason = reason;
	}
	pthread_mutex_unlock(&this->_mutex_follow);
	if (changed) {
		log_notice("replication follow state: %s%s%s", _follow_state_name(st),
			reason.empty() ? "" : " — ", reason.c_str());
	}
	return 0;
}

int stats::follow_set_source(const string& source, const string& source_epoch) {
	pthread_mutex_lock(&this->_mutex_follow);
	this->_follow_source = source;
	this->_follow_source_epoch = source_epoch;
	pthread_mutex_unlock(&this->_mutex_follow);
	return 0;
}

int stats::follow_note_progress(uint64_t applied_lsn) {
	pthread_mutex_lock(&this->_mutex_follow);
	if (applied_lsn > this->_follow_applied_lsn) {
		this->_follow_applied_lsn = applied_lsn;
		this->_follow_last_progress_at = this->get_timestamp();
	}
	pthread_mutex_unlock(&this->_mutex_follow);
	return 0;
}

int stats::follow_note_source_position(uint64_t source_lsn) {
	pthread_mutex_lock(&this->_mutex_follow);
	this->_follow_source_lsn = source_lsn;
	// A position without the time it was observed cannot be acted on, so the
	// two are always written together.
	this->_follow_source_lsn_observed_at = this->get_timestamp();
	pthread_mutex_unlock(&this->_mutex_follow);
	return 0;
}

stats::reconstruction_record stats::get_reconstruction_record() {
	reconstruction_record r;
	pthread_mutex_lock(&this->_mutex_reconstruction);
	r.boot_id = this->_reconstruction_boot_id;
	r.current_id = this->_reconstruction_current_id;
	r.current_state = _reconstruction_state_name(this->_reconstruction_current_state);
	r.last_success_id = this->_reconstruction_last_success_id;
	r.last_success_source = this->_reconstruction_last_success_source;
	pthread_mutex_unlock(&this->_mutex_reconstruction);
	return r;
}
uint64_t stats::get_reconstruction_boot_id() { return this->_reconstruction_boot_id; }
uint64_t stats::get_reconstruction_current_id() { return this->get_reconstruction_record().current_id; }
string stats::get_reconstruction_current_state() { return this->get_reconstruction_record().current_state; }
uint64_t stats::get_reconstruction_last_success_id() { return this->get_reconstruction_record().last_success_id; }
string stats::get_reconstruction_last_success_source() { return this->get_reconstruction_record().last_success_source; }
uint64_t stats::get_reconstruction_completed()		{ return this->_reconstruction_completed.fetch(); }
uint64_t stats::get_reconstruction_failed()				{ return this->_reconstruction_failed.fetch(); }

int stats::increment_proxy_write_dropped(const string& dest) {
	this->_proxy_write_dropped.incr();
	pthread_mutex_lock(&this->_mutex_proxy_write_dropped_by_dest);
	this->_proxy_write_dropped_by_dest[dest]++;
	pthread_mutex_unlock(&this->_mutex_proxy_write_dropped_by_dest);
	return 0;
}

map<string, uint64_t> stats::get_proxy_write_dropped_by_dest() {
	pthread_mutex_lock(&this->_mutex_proxy_write_dropped_by_dest);
	map<string, uint64_t> r = this->_proxy_write_dropped_by_dest;
	pthread_mutex_unlock(&this->_mutex_proxy_write_dropped_by_dest);
	return r;
}
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
