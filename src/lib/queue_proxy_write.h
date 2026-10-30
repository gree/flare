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
 *	queue_proxy_write.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	QUEUE_PROXY_WRITE_H
#define	QUEUE_PROXY_WRITE_H

#include "cluster.h"
#include "storage.h"
#include "thread_queue.h"
#include "op.h"

using namespace std;

namespace gree {
namespace flare {

typedef class queue_proxy_write queue_proxy_write;
typedef boost::shared_ptr<queue_proxy_write> shared_queue_proxy_write;

/**
 *	proxy write queue class
 */
class queue_proxy_write : public thread_queue {
protected:
	cluster*								_cluster;
	storage*								_storage;
	vector<string>					_proxy;
	storage::entry					_entry;
	string									_op_ident;
	op::result							_result;
	string									_result_message;
	bool										_post_proxy;
	uint64_t								_generic_value;
	// a forward to ANOTHER cluster (cluster_replication): its answer is
	// classified and counted per op (cross-cluster audit 2026-10-11)
	bool										_foreign;
	// the forwarding thread running this item: its shutdown request ends the
	// retry wait (foreign and held in-cluster forwards)
	shared_thread						_owner;
	// counted in stats' in-flight forwards until this item is destroyed
	bool										_in_flight;
	// in-cluster replicas this forward is counted in flight for (stats' per-destination gauge);
	// one item is shared by every replica's forwarding thread, so each releases its own
	// destination when it is done with the item (_mutex_repl_dests), the dtor the rest
	vector<string>					_repl_dests;
	pthread_mutex_t					_mutex_repl_dests;
	// never sent: the forwarding thread found its destination a proxy (a map
	// changed while it was queued). A client write forwarded to its master
	// is then routed again (cluster::pre_proxy_write), not failed.
	bool										_skipped;
	// how many times a skipped forward was routed again (bounded)
	int											_reroutes;

public:
	static const int max_retry = 4;
	// A forward to another cluster keeps trying, with backoff, for this long
	// before it is dropped (counted): a destination that restarts or a
	// connection that breaks is ridden out instead of losing every write in
	// between (cross-cluster audit 2026-10-11 — the 4 quick tries above gave
	// up within seconds). The thread's later forwards wait behind it, so the
	// order per key is kept. Tests shorten it.
	static int foreign_retry_window_ms;
	// An in-cluster forward to a replica that does not answer is kept and
	// sent again, with backoff, for this long before it is dropped (counted);
	// each try opens the connection again, so the replica's name is resolved
	// again. L12 (rc68 runs 40341355474, 40449075597, 40449096897): after a
	// replica pod was recreated, its name kept resolving to the old pod's
	// address for up to ~30 s (cached DNS answers), and the 4 quick tries
	// below dropped every forward of that time — writes the clients were
	// told STORED, missing on the replica that was promoted next. 0 keeps
	// the 4 quick tries. Set from proxy-forward-hold-msec.
	static int hold_window_ms;
	// forget which replicas were given up (tests)
	static void clear_held_given_up();

	// What a destination's answer to a forwarded op means for the source.
	// applied: the destination took this change. noop: it already holds this
	// change or a newer one (set NOT_STORED: same or newer version; delete
	// NOT_FOUND: absent already or newer) — a retry or a reordering, not a
	// loss. missing: a touch found no key, so the destination lacks a key
	// this source holds alive (an earlier drop, an expiry or a newer delete
	// there) — not a loss of THIS op, but a divergence signal. failed: any
	// other answer (SERVER_ERROR, CLIENT_ERROR, ERROR, EXISTS, an answer the
	// op cannot produce) — the change is not on the destination.
	enum foreign_answer {
		foreign_applied = 0,
		foreign_noop,
		foreign_missing,
		foreign_failed,
	};
	static foreign_answer classify_foreign_answer(const string& sent_op, op::result r);
	static string foreign_outcome_counter(const string& sent_op, op::result r);

	queue_proxy_write(cluster* cl, storage* st, vector<string> proxy, storage::entry entry, string op_ident);
	virtual ~queue_proxy_write();

	virtual int run(shared_connection c);
	op::result get_result() { return this->_result; };
	string get_result_message() { return this->_result_message; };
	int set_post_proxy(bool post_proxy) { this->_post_proxy = post_proxy; return 0; };
	bool is_post_proxy() { return this->_post_proxy; };
	void set_skipped(bool b) { this->_skipped = b; };
	bool is_skipped() { return this->_skipped; };
	int incr_reroutes() { return ++this->_reroutes; };
	void set_foreign(bool foreign);
	bool is_foreign() { return this->_foreign; };
	void set_owner(shared_thread t) { this->_owner = t; };
	void track_in_flight();
	void track_repl_in_flight(const string& dest);
	void release_repl_in_flight(const string& dest);
	virtual void on_abandoned(const string& dest);
	int set_generic_value(uint64_t generic_value) { this->_generic_value = generic_value; return 0; };
	uint64_t get_generic_value() { return this->_generic_value; };
	string get_op_ident() { return this->_op_ident; };
	storage::entry& get_entry() { return this->_entry; };

protected:
	op_proxy_write* _get_op(string op_ident, shared_connection c);
	int _run_foreign(shared_connection c);
	bool _send_held(shared_connection c, op_proxy_write* p);
	bool _owner_stopping();
};

}	// namespace flare
}	// namespace gree

#endif	// QUEUE_PROXY_WRITE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
