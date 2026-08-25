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
#include "connection_tcp.h"
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
int handler_dump_replication::run() {
	this->_thread->set_peer(this->_replication_server_name, this->_replication_server_port);
	this->_thread->set_state("connect");

	shared_connection c(new connection_tcp(
			   this->_replication_server_name, this->_replication_server_port));
	this->_connection = c;
	if (c->open() < 0) {
		log_err("failed to connect to cluster replication server (name=%s, port=%d)",
				   this->_replication_server_name.c_str(), this->_replication_server_port);
		return -1;
	}

	this->_thread->set_state("execute");

	// Phase 1: Check if WAL replication is possible
	log_info("dump replication handler starting (dest=%s:%d, storage_type=%s)",
		this->_replication_server_name.c_str(),
		this->_replication_server_port,
		storage::type_cast(this->_storage->get_type()).c_str());
	bool use_wal_replication = false;
	bool peer_snapshot_push_supported = false;
#ifdef HAVE_LIBROCKSDB
	// Check if local storage is RocksDB
	if (this->_storage->get_type() == storage::type_rocksdb) {
		storage_rocksdb* local_rocksdb = dynamic_cast<storage_rocksdb*>(this->_storage);
		if (local_rocksdb) {
			// Query master for WAL support
			op_meta* meta_op = new op_meta(c, NULL, NULL);
			bool master_supports_wal = false;

			log_info("checking if master supports RocksDB WAL replication", 0);
			if (meta_op->run_client_features(master_supports_wal) == 0 && master_supports_wal) {
				log_info("master supports RocksDB WAL, attempting incremental replication", 0);
				use_wal_replication = true;
			} else {
				log_info("master does not support RocksDB WAL, using full dump replication", 0);
			}
			peer_snapshot_push_supported = meta_op->get_peer_snapshot_push_supported();
			delete meta_op;
		}
	}

	// Phase 2: Try WAL-based incremental replication if both sides support it
	if (use_wal_replication) {
		this->_thread->set_op("repl_sync_wal");
		storage_rocksdb* local_rocksdb = dynamic_cast<storage_rocksdb*>(this->_storage);

		// Pass our locally remembered LSN and master identity token to
		// the peer. The remote end determines whether the request is
		// compatible with its own lineage (see op_repl_sync_wal).
		//
		// NOTE: The direction of this WAL exchange in cluster_replication
		// mode=duplicate deserves a follow-up audit — the current
		// integration predates the hardening added in Phase A and the
		// semantics of "who streams to whom" in push-mode replication
		// need to be reconciled with the token/lsn_ahead protocol below.
		// The safety invariants still hold: any classified error falls
		// back to the non-destructive full dump path.
		uint64_t last_lsn = local_rocksdb->get_repl_last_lsn();
		string local_master_id = local_rocksdb->get_master_id();
		log_info("attempting WAL replication from LSN %llu (master_id=%s)",
			last_lsn, local_master_id.c_str());

		op_repl_sync_wal* wal_op = new op_repl_sync_wal(c, this->_storage);

		// Configure Phase D throttling. A RocksDB-specific WAL
		// bandwidth/interval of 0 inherits the cluster-wide
		// reconstruction settings, so operators who don't need
		// phase-specific tuning get sensible defaults automatically.
		wal_op->set_max_batch_bytes(local_rocksdb->get_wal_max_batch_bytes());
		int wal_bwlimit = local_rocksdb->get_wal_sync_bwlimit();
		if (wal_bwlimit == 0) {
			wal_bwlimit = this->_cluster->get_reconstruction_bwlimit();
		}
		int wal_interval = local_rocksdb->get_wal_sync_interval();
		if (wal_interval == 0) {
			wal_interval = this->_cluster->get_reconstruction_interval();
		}
		wal_op->set_wal_sync_bwlimit(wal_bwlimit);
		wal_op->set_wal_sync_interval(wal_interval);

		int wal_result = wal_op->run_client(last_lsn, local_master_id);
		op_repl_sync_wal::client_result rc = wal_op->get_client_result();
		delete wal_op;

		if (wal_result == 0 && rc == op_repl_sync_wal::client_success) {
			log_notice("WAL replication completed successfully from LSN %llu", last_lsn);
			return 0;
		}

		switch (rc) {
			case op_repl_sync_wal::client_master_id_mismatch:
				log_warning("WAL sync refused (master_id_mismatch) -> full dump", 0);
				break;
			case op_repl_sync_wal::client_lsn_ahead:
				log_warning("WAL sync refused (lsn_ahead) -> full dump to reset peer", 0);
				break;
			case op_repl_sync_wal::client_lsn_purged:
				log_notice("WAL sync refused (lsn_purged) -> full dump to catch up", 0);
				break;
			default:
				log_warning("WAL replication failed, falling back to full dump replication", 0);
				break;
		}
		local_rocksdb->incr_wal_fallback_to_dump();
		// Fall through to full dump replication
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
				// may carry residue from the WAL exchange above, and a
				// redirect needs a different peer anyway.
				shared_connection cs(new connection_tcp(dest_name, dest_port));
				if (cs->open() < 0) {
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
					log_err("resync failure threshold reached (%llu) -> self-demoting to state_down",
						(unsigned long long)streak);
					this->_cluster->request_down_node(
						this->_cluster->get_server_name(),
						this->_cluster->get_server_port());
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
