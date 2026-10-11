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
 *	handler_dump_replication.cc
 *
 *	implementation of gree::flare::handler_dump_replication
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */

#include "handler_dump_replication.h"
#include "app.h"
#include "connection_tcp.h"
#include "handler_proxy.h"
#include "op_set.h"
#include "op_repl_snapshot_push.h"
#include "op_meta.h"
#include <inttypes.h>

#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#include "op_repl_sync_wal.h"
#endif

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_dump_replication
 */
handler_dump_replication::handler_dump_replication(shared_thread t, cluster* cl, storage* st, string server_name, int server_port):
		thread_handler(t),
		_cluster(cl),
		_storage(st),
		_replication_server_name(server_name),
		_replication_server_port(server_port),
		_bwlimitter() {
}

/**
 *	dtor for handler_dump_replication
 */
handler_dump_replication::~handler_dump_replication() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_dump_replication::seed_connect_attempts = 6;
int handler_dump_replication::seed_retry_base_ms = 5000;

/**
 *	A connection to the destination with a bounded connect (see
 *	handler_cluster_replication::run): a destination that does not answer
 *	SYNs must not hold the seed ~130 s per attempt x 9.
 */
shared_connection handler_dump_replication::_open_bounded(const string& name, int port) {
	connection_tcp* ctp = new connection_tcp(name, port);
	ctp->set_connect_timeout_ms(handler_proxy::proxy_connect_timeout_ms);
	ctp->set_connect_retry_limit(handler_proxy::proxy_connect_retry_limit);
	shared_connection c(ctp);
	if (c->open() < 0) {
		return shared_connection();
	}
	return c;
}

/** false when a shutdown was requested while waiting */
bool handler_dump_replication::_wait_or_shutdown(int ms) {
	for (int waited = 0; waited < ms; waited += 100) {
		if (this->_thread->is_shutdown_request()) {
			return false;
		}
		usleep(100 * 1000);
	}
	return !this->_thread->is_shutdown_request();
}

int handler_dump_replication::run() {
	this->_thread->set_peer(this->_replication_server_name, this->_replication_server_port);
	this->_thread->set_state("connect");

	// The seed's state is in `stats` (cluster_replication_seed) from here on:
	// a seed that never started used to leave nothing but one log line, and
	// the replication stayed "started" (audit 2026-10-11).
	stats_object->set_crepl_seed_state("connecting");
	stats_object->crepl_incr("seed_started");
	shared_connection c;
	int wait_ms = seed_retry_base_ms;
	for (int attempt = 1; attempt <= seed_connect_attempts; attempt++) {
		stats_object->crepl_incr("seed_connect_attempts");
		c = this->_open_bounded(this->_replication_server_name, this->_replication_server_port);
		if (c) {
			break;
		}
		log_err("failed to connect to cluster replication server (name=%s, port=%d) — seed attempt %d of %d, nothing sent yet",
				   this->_replication_server_name.c_str(), this->_replication_server_port, attempt, seed_connect_attempts);
		if (attempt == seed_connect_attempts) {
			break;
		}
		if (!this->_wait_or_shutdown(wait_ms)) {
			stats_object->set_crepl_seed_state("interrupted");
			this->_thread->set_state("shutdown");
			return -1;
		}
		wait_ms = wait_ms * 2 > 60000 ? 60000 : wait_ms * 2;
	}
	if (!c) {
		// Nothing was copied. The forwarding threads still run, so the
		// destination receives later writes but NOT what existed before —
		// it is not a copy of this cluster. Re-enabling (enabled false -> true)
		// starts a new seed.
		stats_object->set_crepl_seed_state("failed_connect");
		stats_object->crepl_incr("seed_failed");
		log_err("CRITICAL: cluster replication SEED NOT STARTED: the destination %s:%d was not reachable in %d attempts — the destination holds no copy of the existing data (re-enable to retry)",
				   this->_replication_server_name.c_str(), this->_replication_server_port, seed_connect_attempts);
		return -1;
	}
	this->_connection = c;

	this->_thread->set_state("execute");
	stats_object->set_crepl_seed_state("transferring");

	log_info("dump replication handler starting (dest=%s:%d, storage_type=%s)",
		this->_replication_server_name.c_str(),
		this->_replication_server_port,
		storage::type_cast(this->_storage->get_type()).c_str());
	bool peer_snapshot_push_supported = false;
#ifdef HAVE_LIBROCKSDB
	// What the destination supports. The answer is used for ONE thing:
	// whether to try a snapshot push.
	//
	// There used to be a "Phase 1" here that asked the DESTINATION for its
	// WAL since this node's repl_last_lsn (op_repl_sync_wal::run_client) and
	// applied it to THIS — the source's — storage, then returned without
	// seeding when that "succeeded". The direction is backwards for a seed:
	// it writes the destination's history into the source. Its only guard
	// was the master_id comparison, and a snapshot-push seed copies the
	// source's files, master_id included — so on the next start() (re-enable,
	// a source master restart) that guard compares the source's id with
	// itself (audit 2026-10-11; E2E cluster-replication-reseed fixes that
	// order). Removed: a seed never applies anything locally.
	if (this->_storage->get_type() == storage::type_rocksdb) {
		op_meta* meta_op = new op_meta(c, NULL, NULL);
		bool peer_rocksdb_wal = false;
		if (meta_op->run_client_features(peer_rocksdb_wal) == 0) {
			peer_snapshot_push_supported = meta_op->get_peer_snapshot_push_supported();
		}
		delete meta_op;
	}
#endif

	// Phase 2.5: physical initial transfer (snapshot push). Only when the
	// destination advertises support; the receiver itself enforces the two
	// preconditions (same partition COUNT and a fresh target) and redirects
	// us to the right partition master behind a Service/LB. Any decline or
	// failure falls through to the legacy merge dump below, unchanged.
	bool via_snapshot_push = false;
#ifdef HAVE_LIBROCKSDB
	if (peer_snapshot_push_supported && this->_storage->get_type() == storage::type_rocksdb) {
		cluster::node self = this->_cluster->get_node(this->_cluster->get_server_name(), this->_cluster->get_server_port());
		int sp_partition = self.node_partition;
		int sp_partition_size = this->_cluster->get_node_partition_map_size();
		if (sp_partition >= 0) {
			this->_thread->set_op("repl_snapshot_push");
			string dest_name = this->_replication_server_name;
			int dest_port = this->_replication_server_port;
			for (int hops = 0; hops < 3; hops++) {
				// FRESH connection per attempt: the shared handler connection
				// carried the features exchange above, and a redirect needs a
				// different peer anyway.
				shared_connection cs = this->_open_bounded(dest_name, dest_port);
				if (!cs) {
					log_warning("snapshot push: cannot connect to %s:%d", dest_name.c_str(), dest_port);
					break;
				}
				op_repl_snapshot_push* sp = new op_repl_snapshot_push(cs, this->_cluster, this->_storage);
				int spr = sp->run_client(sp_partition, sp_partition_size);
				op_repl_snapshot_push::client_result sp_rc = sp->get_client_result();
				string redirect_host = sp->get_redirect_host();
				int redirect_port = sp->get_redirect_port();
				delete sp;
				if (spr == 0) {
					via_snapshot_push = true;
					log_notice("initial transfer completed via snapshot push (partition=%d, dest=%s:%d) -> skipping full dump",
						sp_partition, dest_name.c_str(), dest_port);
					break;
				}
				if (sp_rc == op_repl_snapshot_push::client_result_redirect && redirect_port > 0) {
					log_notice("snapshot push redirected to %s:%d", redirect_host.c_str(), redirect_port);
					dest_name = redirect_host;
					dest_port = redirect_port;
					continue;
				}
				log_notice("snapshot push not applicable (declined or failed) -> full dump", 0);
				break;
			}
		}
	}
#endif

	// Phase 3: Full dump replication (legacy mode or fallback)
	this->_thread->set_op("dump");

	if (!via_snapshot_push && this->_storage->iter_begin() < 0) {
		log_err("database busy", 0);
		stats_object->set_crepl_seed_state("failed_busy");
		stats_object->crepl_incr("seed_failed");
		return -1;
	}

	key_resolver* kr = this->_cluster->get_key_resolver();
	cluster::node n = this->_cluster->get_node(this->_cluster->get_server_name(), this->_cluster->get_server_port());
	int partition = n.node_partition;
	int partition_size = this->_cluster->get_node_partition_map_size();
	int wait = this->_cluster->get_reconstruction_interval();
	this->_bwlimitter.set_bwlimit(static_cast<u_int64_t>(this->_cluster->get_reconstruction_bwlimit()));

	log_notice("starting dump replication (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
			   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, this->_bwlimitter.get_bwlimit());
	uint64_t set_failures = 0;
	uint64_t consecutive_set_failures = 0;
	storage::entry e;
	storage::iteration i;
	while (!via_snapshot_push
			&& (i = this->_storage->iter_next(e.key)) == storage::iteration_continue
			&& this->_thread && !this->_thread->is_shutdown_request()) {
		if (partition >= 0) {
			partition_size = this->_cluster->get_node_partition_map_size();
			int key_hash_value = e.get_key_hash_value(this->_cluster->get_key_hash_algorithm());
			int p = kr->resolve(key_hash_value, partition_size);
			if (p != partition) {
				log_debug("skipping entry (key=%s, key_hash_value=%d, mod=%d, partition=%d, partition_size=%d)",
						   e.key.c_str(), key_hash_value, p, partition, partition_size);
				continue;
			}
		}

		storage::result r;
		if (this->_storage->get(e, r) < 0) {
			if (r == storage::result_not_found) {
				log_info("skipping entry [key not found (perhaps expired)] (key=%s)", e.key.c_str());
			} else {
				log_err("skipping entry [get() error] (key=%s)", e.key.c_str());
			}
			continue;
		}

		// replicate — and CHECK the destination's verdict. run_client()
		// returns 0 for ANY parsed reply (including SERVER_ERROR) and the
		// per-key result was never inspected, so a destination that refused
		// or mis-routed every key still ended in "dump replication
		// completed" + a recorded resync SUCCESS (observed live: a 15.8M-key
		// cross-cluster dump was ACKed key by key and silently stored
		// nowhere). Any result other than STORED counts as a failure; a
		// consecutive run means the destination is systemically not
		// persisting -> abort loudly instead of completing a lie.
		op_set* p = new op_set(this->_connection, NULL, NULL);
		if (p->run_client(e) < 0) {
			delete p;
			set_failures++;
			break;
		}
		if (p->get_result() == op::result_stored) {
			consecutive_set_failures = 0;
		} else {
			set_failures++;
			consecutive_set_failures++;
			if (set_failures <= 5) {
				log_warning("dump set not stored (key=%s, result=%d, msg=%s)",
						   e.key.c_str(), static_cast<int>(p->get_result()), p->get_result_message().c_str());
			}
			if (consecutive_set_failures >= 64) {
				log_err("aborting dump replication: %llu consecutive sets not stored (dest=%s:%d) -> destination is not persisting",
						   (unsigned long long)consecutive_set_failures,
						   this->_replication_server_name.c_str(), this->_replication_server_port);
				delete p;
				break;
			}
		}
		delete p;

		// wait
		long elapsed_usec = this->_bwlimitter.sleep_for_bwlimit(e.size);
		if (wait > 0 && wait-elapsed_usec > 0) {
			log_debug("wait for %d usec", wait);
			usleep(wait-elapsed_usec);
		}
	}

	if (!via_snapshot_push) {
		this->_storage->iter_end();
	}
	bool dump_succeeded = !this->_thread->is_shutdown_request() && set_failures == 0;
	if (set_failures > 0) {
		log_err("dump replication FAILED: %llu set(s) not stored by the destination (dest=%s:%d) -> recorded as resync failure",
				   (unsigned long long)set_failures,
				   this->_replication_server_name.c_str(), this->_replication_server_port);
	}
	// The seed's outcome, for `stats`. "completed_*" says the transfer ran
	// to its end with every set STORED (or the snapshot push confirmed) —
	// not that the destination equals this cluster: writes forwarded during
	// the seed can still have been dropped (counted separately), and a
	// failed seed is NOT retried here (a destination already partly written
	// answers NOT_STORED for what it holds, which the dump counts as failed).
	if (via_snapshot_push) {
		stats_object->set_crepl_seed_state("completed_snapshot_push");
		stats_object->crepl_incr("seed_completed");
	} else if (dump_succeeded) {
		stats_object->set_crepl_seed_state("completed_dump");
		stats_object->crepl_incr("seed_completed");
	} else if (this->_thread->is_shutdown_request()) {
		stats_object->set_crepl_seed_state("interrupted");
	} else {
		stats_object->set_crepl_seed_state("failed_transfer");
		stats_object->crepl_incr("seed_failed");
	}
	if (dump_succeeded) {
		log_notice("dump replication completed (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%" PRIu64 ")",
				   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, this->_bwlimitter.get_bwlimit());
	} else if (this->_thread->is_shutdown_request()) {
		this->_thread->set_state("shutdown");
		log_warning("dump replication interruptted (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%" PRIu64 ")",
				   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, this->_bwlimitter.get_bwlimit());
	}

#ifdef HAVE_LIBROCKSDB
	// RocksDB resync accounting: after every attempt (WAL-incremental
	// or full-dump) record success/failure. If the streak of failures
	// reaches the configured threshold, ask the index to mark this
	// node `state_down` so clients are steered away while operators
	// investigate. The local RocksDB directory is left untouched, so
	// data is preserved and an operator can `up_node` after repair.
	// This path is a no-op for non-RocksDB backends.
	if (this->_storage->get_type() == storage::type_rocksdb) {
		storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
		if (rdb) {
			uint64_t streak = rdb->notify_resync_result(dump_succeeded);
			if (dump_succeeded) {
				log_debug("resync success; failure streak reset (was handled by notify)", 0);
			} else {
				log_warning("resync failure streak now %llu", (unsigned long long)streak);
				if (rdb->should_self_demote()) {
					// request_down_node is an INDEX-side API: it enqueues to
					// thread_type_controller, which only flarei starts (see
					// src/flarei/flarei.cc). A flared under the Kubernetes
					// operator has no such thread, so the enqueue fails and
					// NOTHING is sent anywhere. Report what actually happened
					// — the old message claimed a demotion that never
					// occurred, which is worse than silence when someone is
					// reading these logs during an incident. The condition is
					// still exported as rocksdb_resync_failure_count and
					// alerted on (FlareResyncFailing).
					if (this->_cluster->request_down_node(
							this->_cluster->get_server_name(),
							this->_cluster->get_server_port()) < 0) {
						log_err("resync failure threshold reached (%llu) but SELF-DEMOTE IS UNAVAILABLE in this process (no controller thread; that path exists only in index-managed deployments). This node keeps its role and may be serving stale data — an operator or a human must act.",
							(unsigned long long)streak);
					} else {
						log_err("resync failure threshold reached (%llu) -> requested self-demote to state_down",
							(unsigned long long)streak);
					}
				}
			}
		}
	}
#endif

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
