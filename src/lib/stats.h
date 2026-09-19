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
 *	stats.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	STATS_H
#define	STATS_H

#include <boost/lexical_cast.hpp>

#include <map>
#include <pthread.h>

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
	// Writes the master gave up forwarding to a replica: queue_proxy_write
	// exhausted its retries and DROPPED the op. The client already got its
	// success (the master's own write succeeded), so this is silent replica
	// divergence — the only signal that it happened. Monotonic.
	AtomicCounter _proxy_write_dropped;
	// The same drops broken down BY DESTINATION, so a controller can tell
	// WHICH replica is now behind and resync only that one. The aggregate
	// counter above cannot: it says a replica diverged, not which. Drops are
	// rare, so a mutex-guarded map costs nothing on the hot path (it is only
	// touched after four failed retries).
	pthread_mutex_t _mutex_proxy_write_dropped_by_dest;
	map<string, uint64_t> _proxy_write_dropped_by_dest;
	// Reconstruction lifecycle of THIS node, counted once per request (a
	// request is one handler_reconstruction; its internal retries are not
	// separate requests). "started" is what a controller compares against
	// after it asks for a resync: without it, a resync request that never
	// reached flared (role diff lost, map ignored, state-only change) is
	// indistinguishable from one that ran instantly. "completed" is the
	// evidence that a full copy or WAL catch-up finished; "failed" is the
	// permanent give-up after retries. Monotonic for the process lifetime.
	AtomicCounter _reconstruction_started;
	AtomicCounter _reconstruction_completed;
	AtomicCounter _reconstruction_failed;
	// ONE completion record, so a controller can tell "the current
	// reconstruction of this process succeeded from this source" apart from
	// cumulative counters (a failed or aborted handler leaves started and
	// completed permanently unequal, and a restart resets both to values a
	// previous process may also have shown):
	//   boot_id           random per process — distinguishes processes even
	//                     when every counter happens to match;
	//   current_id        the id (= started ordinal) of the latest handler;
	//   current_state     none / running / succeeded / failed / aborted;
	//   last_success_id   id of the last handler that succeeded;
	//   last_success_source  master host:port that handler copied from.
	pthread_mutex_t _mutex_reconstruction;
	pthread_mutex_t _mutex_follow;
	bool _follow_enabled;
	string _follow_source;
	string _follow_source_epoch;
	int _follow_state;
	string _follow_last_reason;
	uint64_t _follow_applied_lsn;
	uint64_t _follow_source_lsn;
	time_t _follow_source_lsn_observed_at;
	time_t _follow_last_progress_at;
	uint64_t _reconstruction_boot_id;
	uint64_t _reconstruction_current_id;
	int _reconstruction_current_state;
	uint64_t _reconstruction_last_success_id;
	string _reconstruction_last_success_source;
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
	inline int increment_proxy_write_dropped()   { this->_proxy_write_dropped.incr();return 0; };
	int increment_proxy_write_dropped(const string& dest);
	inline int increment_reconstruction_started()   { this->_reconstruction_started.incr();return 0; };
	inline int increment_reconstruction_completed() { this->_reconstruction_completed.incr();return 0; };
	inline int increment_reconstruction_failed()    { this->_reconstruction_failed.incr();return 0; };
	enum reconstruction_state { reconstruction_none = 0, reconstruction_running, reconstruction_succeeded, reconstruction_failed_state, reconstruction_aborted };
	// Every notification carries the id the handler was GIVEN at begin(), so
	// an older handler finishing after a newer one started cannot write the
	// newer id into the record (review: A begins #1, B begins #2, A succeeds
	// must not yield "latest #2 succeeded"). Only the CURRENT handler's
	// notification changes the current state; last_success only advances.
	// begin() allocates the id and updates the record under ONE lock.
	uint64_t reconstruction_begin();
	int reconstruction_succeeded_from(uint64_t id, const string& source);
	int reconstruction_failed_final(uint64_t id);
	int reconstruction_aborted_by_shutdown(uint64_t id);
	struct reconstruction_record {
		uint64_t boot_id;
		uint64_t current_id;
		string current_state;
		uint64_t last_success_id;
		string last_success_source;
	};
	/// One consistent snapshot under a single lock (for `stats`).
	reconstruction_record get_reconstruction_record();

	// ---- CONTINUOUS REPLICATION, follower side (SAF-10b stage 3b) --------
	// What the operator needs to tell "following" from "connected" and from
	// "caught up" (design §5.1). Every field is read as ONE snapshot: a
	// position without the time it was observed, or a state without a
	// reason, cannot be acted on.
	enum follow_state {
		follow_idle = 0,		// not following: this node is not a WAL-mode replica
		follow_initial_sync,	// has a copy, still catching up for the first time
		follow_following,		// connected and applying
		follow_disconnected,	// lost the connection; RESUMES from the position, never a rebuild by itself
		follow_needs_rebuild,	// history gone, source epoch changed, or a batch could not be decoded
		follow_error,			// storage or protocol failure; retried
	};
	struct follow_record {
		bool     enabled;				// the mode is on for this node
		string   source;				// peer being followed, empty when idle
		string   source_epoch;			// the history the position belongs to
		string   state;
		string   last_reason;			// why the last reconnect or rebuild
		uint64_t applied_lsn;			// contiguously applied position
		uint64_t source_lsn;			// the master's position...
		time_t   source_lsn_observed_at;	// ...and when that was observed
		time_t   last_progress_at;		// last time the position advanced
	};
	follow_record get_follow_record();
	// Transitions. follow_note_progress() is the only one that moves the
	// applied position, and it is called after the position was durably
	// recorded, never before.
	int follow_set_state(follow_state st, const string& reason);
	int follow_set_source(const string& source, const string& source_epoch);
	int follow_note_progress(uint64_t applied_lsn);
	int follow_note_source_position(uint64_t source_lsn);
	int follow_set_enabled(bool enabled);
	uint64_t get_reconstruction_boot_id();
	uint64_t get_reconstruction_current_id();
	string get_reconstruction_current_state();
	uint64_t get_reconstruction_last_success_id();
	string get_reconstruction_last_success_source();
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
	virtual uint32_t get_curr_connections(thread_pool* req_tp, thread_pool* other_tp);
	uint32_t get_total_connections();
	uint32_t get_connection_structures();
	uint64_t get_cmd_get();
	uint64_t get_cmd_set();
	uint64_t get_get_hits();
	uint64_t get_get_misses();
	uint64_t get_proxy_write_dropped();
	map<string, uint64_t> get_proxy_write_dropped_by_dest();
	uint64_t get_reconstruction_started();
	uint64_t get_reconstruction_completed();
	uint64_t get_reconstruction_failed();
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
	uint32_t get_threads(thread_pool* req_tp, thread_pool* other_tp);
	uint32_t get_pool_threads(thread_pool* req_tp, thread_pool* other_tp);
};

}	// namespace flare
}	// namespace gree

#endif	// STATS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
