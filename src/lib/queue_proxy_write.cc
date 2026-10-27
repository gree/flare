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
 *	queue_proxy_write.cc
 *
 *	implementation of gree::flare::queue_proxy_write
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "queue_proxy_write.h"

#include <cctype>
#include <time.h>
#include <boost/lexical_cast.hpp>
#include "handler_proxy.h"
#include "app.h"
#include "connection_tcp.h"
#include "op_proxy_write.h"
#include "op_add.h"
#include "op_append.h"
#include "op_cas.h"
#include "op_decr.h"
#include "op_delete.h"
#include "op_incr.h"
#include "op_prepend.h"
#include "op_set.h"
#include "op_replace.h"
#include "op_touch.h"
#include "op_gat.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_proxy_write
 */
queue_proxy_write::queue_proxy_write(cluster* cl, storage* st, vector<string> proxy, storage::entry entry, string op_ident):
		thread_queue("proxy_write"),
		_cluster(cl),
		_storage(st),
		_proxy(proxy),
		_entry(entry),
		_op_ident(op_ident),
		_result(op::result_none),
		_result_message(""),
		_post_proxy(false),
		_generic_value(0),
		_foreign(false),
		_in_flight(false) {
}

/**
 *	dtor for queue_proxy_write
 */
queue_proxy_write::~queue_proxy_write() {
	if (this->_in_flight) {
		stats_object->crepl_in_flight_sub();
	}
	for (vector<string>::const_iterator it = this->_repl_dests.begin(); it != this->_repl_dests.end(); it++) {
		stats_object->repl_in_flight_sub(*it);
	}
}

/**
 *	Count this in-cluster forward as in flight toward replica `dest` until
 *	the item is destroyed. Called before it is queued for `dest`.
 */
void queue_proxy_write::track_repl_in_flight(const string& dest) {
	this->_repl_dests.push_back(dest);
	stats_object->repl_in_flight_add(dest);
}

/**
 *	Count this asynchronous cross-cluster forward as in flight until it is
 *	destroyed. Called once, BEFORE it is queued: a forward that is queued
 *	but not yet counted as enqueued, or answered but not yet released, is
 *	still in flight — the counters alone cannot say so (forward_enqueued is
 *	counted after the queue took it, the outcome before the item is gone).
 */
void queue_proxy_write::track_in_flight() {
	if (!this->_in_flight) {
		this->_in_flight = true;
		stats_object->crepl_in_flight_add();
	}
}
// }}}

// {{{ operator overloads
// }}}

/**
 *	The forward's thread shut down with it still queued: a write the client
 *	was already told STORED that the destination will never get. Counted
 *	like any other replica drop (the repair path sees it) — it vanished
 *	without a trace before. A pre-proxy item is the client's own failure.
 */
void queue_proxy_write::on_abandoned(const string& dest) {
	if (!this->_post_proxy) {
		return;
	}
	if (dest.empty()) {
		stats_object->increment_proxy_write_dropped();
	} else {
		stats_object->increment_proxy_write_dropped(dest);
	}
	if (this->_foreign) {
		stats_object->crepl_incr("forward_dropped_abandoned");
	}
	if (stats_object->diag_enabled()) {
		stats_object->diag_incr("fwd_abandoned:" + dest);
	}
	static AtomicCounter abandoned_logged(0);
	if (abandoned_logged.incr() % 100 == 1) {
		log_err("proxy write ABANDONED (dest=%s, op=%s, key=%s, version=%u): its thread shut down with it queued — counted; replica diverges until it is repaired (logged 1 in 100)",
			dest.c_str(), this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
	}
}

/**
 *	A forward to another cluster. Its answer is always READ: a client's
 *	noreply is not passed on, or the destination's verdict (and a broken
 *	connection) could never be seen and every outcome would look applied.
 */
void queue_proxy_write::set_foreign(bool foreign) {
	this->_foreign = foreign;
	if (foreign) {
		this->_entry.option &= ~storage::option_noreply;
	}
}

queue_proxy_write::foreign_answer queue_proxy_write::classify_foreign_answer(const string& sent_op, op::result r) {
	if (sent_op == "delete") {
		if (r == op::result_deleted) return foreign_applied;
		if (r == op::result_not_found) return foreign_noop;
		return foreign_failed;
	}
	if (sent_op == "touch") {
		if (r == op::result_touched || r == op::result_ok) return foreign_applied;
		if (r == op::result_not_found) return foreign_missing;
		return foreign_failed;
	}
	// every other post-proxy op is sent as a versioned set (_get_op)
	if (r == op::result_stored) return foreign_applied;
	if (r == op::result_not_stored) return foreign_noop;
	return foreign_failed;
}

/**
 *	The outcome counter of an ANSWERED forward: forward_applied, or
 *	forward_{noop,missing,failed}_<sent op>_<answer, lower case>. The sent op
 *	is set, delete or touch (_get_op sends every other post-proxy op as a
 *	versioned set, gat as touch), so the names are a closed set — the
 *	operator's switch gate (Migration/Types.lean forwardTerminal) accepts
 *	exactly that set and holds on any other name; the cutter test
 *	test_foreign_outcome_counters_are_the_gate_set pins the two together.
 */
string queue_proxy_write::foreign_outcome_counter(const string& sent_op, op::result r) {
	const string rname = op::result_cast(r);
	string rkey;
	for (string::const_iterator ci = rname.begin(); ci != rname.end(); ci++) {
		rkey += (*ci == ' ') ? '_' : static_cast<char>(tolower(*ci));
	}
	if (rkey.empty()) {
		rkey = "none";
	}
	switch (classify_foreign_answer(sent_op, r)) {
		case foreign_applied:
			return "forward_applied";
		case foreign_noop:
			return "forward_noop_" + sent_op + "_" + rkey;
		case foreign_missing:
			return "forward_missing_" + sent_op + "_" + rkey;
		case foreign_failed:
		default:
			return "forward_failed_" + sent_op + "_" + rkey;
	}
}

// {{{ public methods
int queue_proxy_write::run(shared_connection c) {
	if (this->_foreign && this->_post_proxy) {
		return this->_run_foreign(c);
	}
#ifdef DEBUG
	if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
		log_debug("proxy request (write) (host=%s, port=%d, op=%s, key=%s, version=%u)", ctp->get_host().c_str(), ctp->get_port(), this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
	}
#endif

	// a forward to a replica of this cluster waits out a destination that does
	// not answer (hold_window_ms) instead of dropping at once
	const bool held = this->_post_proxy && queue_proxy_write::hold_window_ms > 0;

	// FAIL FAST (forward-window-steps 38048708017): the destination's
	// connection is down and its last open TIMED OUT moments ago — count this forward
	// as dropped now (the repair path sees it) instead of queueing it behind
	// another bounded connect; a later forward tries to connect again.
	// Not for a held forward: it waits the destination out itself.
	if (connection_tcp* fctp = dynamic_cast<connection_tcp*>(c.get())) {
		if (!held && !fctp->is_available() && fctp->open_failed_within(handler_proxy::proxy_fail_fast_window_ms)) {
			char dest[BUFSIZ];
			snprintf(dest, sizeof(dest), "%s:%d", fctp->get_host().c_str(), fctp->get_port());
			if (!this->_post_proxy) {
				// a client write forwarded TO the master: the client hears the
				// failure (no replica fell behind, nothing to count)
				return -1;
			}
			stats_object->increment_proxy_write_dropped(string(dest));
			if (stats_object->diag_enabled()) {
				stats_object->diag_incr(string("fwd_dropped_fast:") + dest);
			}
			static AtomicCounter fast_logged(0);
			if (fast_logged.incr() % 100 == 1) {
				log_err("proxy write DROPPED at once (dest=%s, op=%s, key=%s, version=%u): the connection's last open timed out %d ms ago or less — counted; replica diverges until it is repaired (logged 1 in 100)",
						dest, this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version, handler_proxy::proxy_fail_fast_window_ms);
			}
			return -1;
		}
	}

	op_proxy_write* p = this->_get_op(this->_op_ident, c);
	if (p == NULL) {
		return -1;
	}
	p->set_proxy(this->_proxy);
	// SAF-10b stage 3: carry the source's replication identity with the
	// change, so the destination can order it against the same change
	// arriving through the WAL stream instead of overwriting blindly. The
	// label was captured inside the key's critical section when the master
	// wrote locally (design §3.9(B)); an empty epoch means the source cannot
	// identify its history, in which case nothing is sent and the receiver
	// behaves exactly as before.
	if (this->_cluster != NULL && this->_cluster->get_repl_identity_forward()
			&& this->_storage != NULL && this->_entry.seq_label > 0) {
		const string epoch = this->_storage->get_source_epoch();
		if (!epoch.empty()) {
			this->_entry.repl_tag = epoch + "/" + boost::lexical_cast<string>(this->_entry.seq_label);
		}
	}

	if (held) {
		if (!this->_send_held(c, p)) {
			delete p;
			return -1;
		}
	}
	int retry = held ? 1 : queue_proxy_write::max_retry;
	while (!held && retry > 0) {
		if (p->run_client(this->_entry) >= 0) {
			break;
		}
		if (c->is_available() == false) {
#ifdef DEBUG
			if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
				log_debug("reconnecting (host=%s, port=%d)", ctp->get_host().c_str(), ctp->get_port());
			}
#endif
			c->open();
		}
		retry--;
	}
	if (retry <= 0 && !this->_post_proxy) {
		// A client write forwarded TO its master (pre-proxy) that could not be
		// delivered: the client hears the failure. No replica fell behind, so
		// it is NOT counted as a replica drop (it was before: a refused master
		// connection asked the repair path to rebuild a replica for nothing).
		delete p;
		return -1;
	}
	if (retry <= 0) {
		// GIVING UP on a replica write. Nothing above us looks at this return
		// value (thread::run() ignores it) and the client was already told
		// STORED by the master, so the op is now silently missing on that
		// replica until its next reconstruction. Make it loud and countable —
		// this used to be completely invisible.
		if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
			log_err("proxy write DROPPED after %d retries (dest=%s:%d, op=%s, key=%s, version=%u): replica now diverges until it reconstructs",
					queue_proxy_write::max_retry, ctp->get_host().c_str(), ctp->get_port(),
					this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
			// Attribute it: a controller needs to know WHICH replica fell
			// behind so it can resync that one instead of guessing.
			char dest[BUFSIZ];
			snprintf(dest, sizeof(dest), "%s:%d", ctp->get_host().c_str(), ctp->get_port());
			stats_object->increment_proxy_write_dropped(string(dest));
		} else {
			log_err("proxy write DROPPED after %d retries (op=%s, key=%s, version=%u): replica now diverges until it reconstructs",
					queue_proxy_write::max_retry, this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
			stats_object->increment_proxy_write_dropped();
		}
		delete p;
		return -1;
	}

	this->_success = true;
	this->_result = p->get_result();
	if (stats_object->diag_enabled() && this->_post_proxy) {
		if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
			stats_object->diag_incr("fwd_answered:" + ctp->get_host() + ":" + boost::lexical_cast<string>(ctp->get_port())
				+ ":" + boost::lexical_cast<string>(static_cast<int>(this->_result)));
		}
	}
	// DIAGNOSTIC (copy-identity 11, manual run 37899958227: 10 forwarded writes
	// acknowledged by the master never reached a replica, with no drop logged
	// or counted): the replica ANSWERED, but not with a success — its answer
	// was ignored here. Logged (rate-limited) with the destination; no change
	// of behaviour (whether such an answer is a drop is not decided yet).
	// terminal outcome of an answered in-cluster forward, per destination
	// (node key = host:port, the same key as proxy_write_dropped[...])
	if (this->_post_proxy && !this->_foreign) {
		if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
			const string dest = ctp->get_host() + ":" + boost::lexical_cast<string>(ctp->get_port());
			if (this->_result == op::result_not_stored) {
				stats_object->increment_proxy_write_skipped(dest);
			} else if (this->_result != op::result_stored && this->_result != op::result_deleted
					&& this->_result != op::result_touched && this->_result != op::result_ok
					&& this->_result != op::result_not_found) {
				stats_object->increment_proxy_write_failed(dest);
			}
		}
	}
	if (this->_result != op::result_stored && this->_result != op::result_deleted
			&& this->_result != op::result_touched && this->_result != op::result_ok
			&& this->_result != op::result_not_found) {
		static AtomicCounter unexpected_logged(0);
		if (unexpected_logged.incr() % 100 == 1) {
			const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get());
			log_warning("proxy write ANSWERED but not stored by the replica (dest=%s:%d, op=%s, key=%s, version=%u, result=%s) — the replica may now miss this write (logged 1 in 100)",
				ctp ? ctp->get_host().c_str() : "?", ctp ? ctp->get_port() : 0,
				this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version,
				op::result_cast(this->_result).c_str());
		}
	}
	// :(
	log_debug("result: %s:%d", p->get_ident().c_str(), this->_result);
	if ((p->get_ident() == "incr" || p->get_ident() == "decr") && this->_result == op::result_stored) {
		log_debug("available: %d", this->_entry.is_data_available());
		if (this->_entry.is_data_available()) {
			char buf[BUFSIZ];
			memcpy(buf, this->_entry.data.get(), this->_entry.size);
			snprintf(buf+this->_entry.size, sizeof(buf)-this->_entry.size, "%s", line_delimiter);
			this->_result_message = buf;
		} else {
			this->_result_message = p->get_result_message();
		}
	} else {
		this->_result_message = p->get_result_message();
	}
	delete p;

	return 0;
}
// }}}

// {{{ protected methods
int queue_proxy_write::foreign_retry_window_ms = 120 * 1000;

namespace {
uint64_t foreign_now_ms() {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
}	// anonymous namespace

bool queue_proxy_write::_owner_stopping() {
	return this->_owner && this->_owner->is_shutdown_request() != thread::shutdown_request_none;
}

int queue_proxy_write::hold_window_ms = 0;

/**
 *	Send one in-cluster forward to a replica, waiting out a destination that
 *	does not answer (L12).
 *
 *	- Each try opens the connection again when it is down, which resolves the
 *	  replica's name again: a replica recreated under the same name is reached
 *	  at its new address once the name resolves to it.
 *	- A failed exchange closes the connection (what is left on it is not
 *	  trusted). Sending a versioned change again is idempotent: one applied
 *	  whose reply was lost comes back NOT_STORED / NOT_FOUND.
 *	- Waits 200 ms, 400 ms ... 2 s between tries, for hold_window_ms in all.
 *	  The thread's later forwards wait behind this one (order kept); they are
 *	  counted in flight, so a graceful stop waits for them too.
 *	- Ends early, counted as dropped: the thread is stopping, or the
 *	  destination is a proxy in the node map now (it holds no copy to keep).
 *	- After a forward waited out the whole window, the destination is marked
 *	  given up: later forwards try once each (counted at once when it fails)
 *	  until one is delivered, so a dead replica does not hold every write.
 *
 *	Returns true when the destination answered (the answer is classified by
 *	the caller); false when the forward is dropped (counted here).
 */
bool queue_proxy_write::_send_held(shared_connection c, op_proxy_write* p) {
	connection_tcp* ctp = dynamic_cast<connection_tcp*>(c.get());
	const string dest = ctp ? ctp->get_host() + ":" + boost::lexical_cast<string>(ctp->get_port()) : "";
	const bool given_up = ctp != NULL && ctp->sender_given_up();
	const uint64_t started = foreign_now_ms();
	int wait_ms = 200;
	int attempts = 0;
	const char* why = "its hold window ended";
	for (;;) {
		if (!c->is_available()) {
			c->open();
		}
		attempts++;
		if (c->is_available() && p->run_client(this->_entry) >= 0) {
			if (given_up) {
				ctp->set_sender_given_up(false);
				log_notice("replica %s answers again — forwards to it wait out their hold window again", dest.c_str());
			}
			if (attempts > 1) {
				static AtomicCounter held_logged(0);
				if (held_logged.incr() % 100 == 1) {
					log_notice("proxy write delivered after %d attempts in %llu ms (dest=%s, op=%s, key=%s, version=%u) (logged 1 in 100)",
						attempts, (unsigned long long)(foreign_now_ms() - started), dest.c_str(),
						this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
				}
			}
			return true;
		}
		c->close();
		if (given_up) {
			why = "an earlier forward to it already waited out its hold window";
			break;
		}
		if (this->_owner_stopping()) {
			why = "the forwarding thread is stopping";
			break;
		}
		if (this->_cluster != NULL && ctp != NULL
				&& this->_cluster->get_node(ctp->get_host(), ctp->get_port()).node_role == cluster::role_proxy) {
			why = "the destination is a proxy in the node map now";
			break;
		}
		if (foreign_now_ms() - started >= (uint64_t)queue_proxy_write::hold_window_ms) {
			break;
		}
		for (int slept = 0; slept < wait_ms && !this->_owner_stopping(); slept += 100) {
			usleep(100 * 1000);
		}
		wait_ms = wait_ms * 2 > 2000 ? 2000 : wait_ms * 2;
	}

	if (dest.empty()) {
		stats_object->increment_proxy_write_dropped();
	} else {
		stats_object->increment_proxy_write_dropped(dest);
	}
	if (!given_up && ctp != NULL && !this->_owner_stopping()
			&& foreign_now_ms() - started >= (uint64_t)queue_proxy_write::hold_window_ms) {
		ctp->set_sender_given_up(true);
	}
	static AtomicCounter dropped_logged(0);
	if (dropped_logged.incr() % 100 == 1) {
		log_err("proxy write DROPPED after %d attempts in %llu ms (dest=%s, op=%s, key=%s, version=%u): %s — counted; replica now diverges until it reconstructs (logged 1 in 100)",
			attempts, (unsigned long long)(foreign_now_ms() - started), dest.c_str(),
			this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version, why);
	}
	return false;
}

/**
 *	One forward to ANOTHER cluster (cluster_replication), until the
 *	destination answers or the retry window ends.
 *
 *	- The destination answers: classify_foreign_answer decides whether the
 *	  change is there; a failed answer is counted as dropped.
 *	- No answer (connect refused or timed out, name not resolvable, the
 *	  connection broke, the reply did not parse): reconnect and send again
 *	  — a forward applied whose reply was lost comes back NOT_STORED /
 *	  NOT_FOUND, a noop — waiting 1, 2, 4 ... 10 s in between, for
 *	  foreign_retry_window_ms in all; then dropped and counted, and the
 *	  connection is marked given up: later forwards make ONE attempt each
 *	  (counted at once when it fails) until one is delivered, so a dead
 *	  destination does not hold every write for the whole window.
 *	- The thread is asked to stop: the wait ends; the forward is counted.
 */
int queue_proxy_write::_run_foreign(shared_connection c) {
	connection_tcp* ctp = dynamic_cast<connection_tcp*>(c.get());
	char dest[BUFSIZ];
	snprintf(dest, sizeof(dest), "%s:%d", ctp ? ctp->get_host().c_str() : "?", ctp ? ctp->get_port() : 0);

	op_proxy_write* p = this->_get_op(this->_op_ident, c);
	if (p == NULL) {
		stats_object->increment_proxy_write_dropped(string(dest));
		stats_object->crepl_incr("forward_dropped_unknown_op");
		return -1;
	}
	p->set_proxy(this->_proxy);

	const bool given_up = ctp != NULL && ctp->sender_given_up();
	const uint64_t started = foreign_now_ms();
	int wait_ms = 1000;
	bool answered = false;
	int attempts = 0;
	for (;;) {
		if (!c->is_available()) {
			c->open();
		}
		attempts++;
		if (c->is_available() && p->run_client(this->_entry) >= 0) {
			answered = true;
			// SERVER_ERROR is the destination's TRANSIENT refusal — a node that
			// restarted and has not got its role back answers it (E2E
			// cluster-replication-faults restart test on 50f65f1: 21 changes
			// answered SERVER_ERROR, none stored, none counted). Resending a
			// versioned change is idempotent, so it is retried like no answer,
			// within the same window; anything else the destination says is
			// final.
			if (p->get_result() != op::result_server_error) {
				break;
			}
		} else {
			answered = false;
			// whatever is left on a failed exchange is not trusted: resync
			c->close();
		}
		if (given_up || this->_owner_stopping()
				|| foreign_now_ms() - started >= (uint64_t)foreign_retry_window_ms) {
			break;
		}
		if (answered) {
			stats_object->crepl_incr("forward_server_error_retried");
		}
		for (int slept = 0; slept < wait_ms && !this->_owner_stopping(); slept += 100) {
			usleep(100 * 1000);
		}
		wait_ms = wait_ms * 2 > 10000 ? 10000 : wait_ms * 2;
	}

	if (!answered) {
		delete p;
		stats_object->increment_proxy_write_dropped(string(dest));
		if (given_up) {
			stats_object->crepl_incr("forward_dropped_down");
			static AtomicCounter down_logged(0);
			if (down_logged.incr() % 100 == 1) {
				log_err("cluster replication write DROPPED (dest=%s, op=%s, key=%s, version=%u): the destination is still unreachable after an earlier forward waited out its retry window — counted; the destination diverges until it is repaired (logged 1 in 100)",
					dest, this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
			}
		} else {
			stats_object->crepl_incr(this->_owner_stopping() ? "forward_dropped_stopping" : "forward_dropped_retries");
			if (ctp != NULL && !this->_owner_stopping()) {
				ctp->set_sender_given_up(true);
			}
			log_err("cluster replication write DROPPED after %d attempts in %llu ms (dest=%s, op=%s, key=%s, version=%u) — counted; later forwards to this destination try once each until one is delivered; the destination diverges until it is repaired",
				attempts, (unsigned long long)(foreign_now_ms() - started), dest, this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
		}
		return -1;
	}

	if (p->get_result() == op::result_server_error) {
		// refused for the whole window (or once, when already given up):
		// later forwards try once each, as for a destination that is down
		if (ctp != NULL && !given_up && !this->_owner_stopping()) {
			ctp->set_sender_given_up(true);
		}
	} else if (given_up && ctp != NULL) {
		ctp->set_sender_given_up(false);
		log_notice("cluster replication destination %s answers again — forwards wait out their retry window again", dest);
	}
	if (attempts > 1) {
		stats_object->crepl_incr("forward_retried");
	}
	this->_success = true;
	this->_result = p->get_result();
	this->_result_message = p->get_result_message();

	// The destination ANSWERED. Whether that answer put the change there
	// depends on the op (classify_foreign_answer). A failed answer is a drop
	// like an exhausted retry — counted under the destination, where the
	// operator and the runbook look — and was only a rate-limited warning
	// before (audit 2026-10-11).
	const string sent = p->get_ident();
	const string rname = op::result_cast(this->_result);
	const string counter = foreign_outcome_counter(sent, this->_result);
	switch (classify_foreign_answer(sent, this->_result)) {
		case foreign_applied:
			stats_object->crepl_incr(counter);
			break;
		case foreign_noop:
			stats_object->crepl_incr(counter);
			break;
		case foreign_missing: {
			stats_object->crepl_incr(counter);
			static AtomicCounter missing_logged(0);
			if (missing_logged.incr() % 100 == 1) {
				log_warning("cluster replication: the destination has no key this source holds alive (dest=%s, op=%s, key=%s, version=%u, result=%s) — an earlier drop, an expiry or a newer delete there; the destination may diverge (logged 1 in 100)",
					dest, sent.c_str(), this->_entry.key.c_str(), this->_entry.version, rname.c_str());
			}
			break;
		}
		case foreign_failed:
		default: {
			this->_success = false;
			stats_object->crepl_incr(counter);
			stats_object->increment_proxy_write_dropped(string(dest));
			static AtomicCounter failed_logged(0);
			if (failed_logged.incr() % 100 == 1) {
				log_err("cluster replication write NOT STORED by the destination (dest=%s, op=%s, key=%s, version=%u, result=%s %s) — counted as dropped; the destination diverges until it is repaired (logged 1 in 100)",
					dest, sent.c_str(), this->_entry.key.c_str(), this->_entry.version, rname.c_str(), this->_result_message.c_str());
			}
			break;
		}
	}
	delete p;
	return this->_success ? 0 : -1;
}

op_proxy_write* queue_proxy_write::_get_op(string op_ident, shared_connection c) {
	if (op_ident == "set") {
		return new op_set(c, this->_cluster, this->_storage);
	} else if (op_ident == "add") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_add(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "replace") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_replace(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "cas") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_cas(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "append") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_append(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "prepend") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_prepend(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "incr") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			op_incr* p = new op_incr(c, this->_cluster, this->_storage);
			p->set_value(this->_generic_value);
			return p;
		}
	} else if (op_ident == "decr") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			op_incr* p = new op_decr(c, this->_cluster, this->_storage);
			p->set_value(this->_generic_value);
			return p;
		}
	} else if (op_ident == "delete") {
		return new op_delete(c, this->_cluster, this->_storage);
	} else if (op_ident == "touch") {
		return new op_touch(c, this->_cluster, this->_storage);
	} else if (op_ident == "gat") {
		if (this->is_post_proxy()) {
			return new op_touch(c, this->_cluster, this->_storage);
		} else {
			return new op_gat(c, this->_cluster, this->_storage);
		}
	}
	log_warning("unknown op (ident=%s)", op_ident.c_str());

	return NULL;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
