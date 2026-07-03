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
		this->_notify_resync_result(false);
		return -1;
	}

	this->_thread->set_state("execute");

	log_info("dump replication handler starting (dest=%s:%d, storage_type=%s)",
		this->_replication_server_name.c_str(),
		this->_replication_server_port,
		storage::type_cast(this->_storage->get_type()).c_str());

	// Phase 1: probe the destination's capabilities and lineage
	bool peer_supports_wal = false;
	string peer_master_id;
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* local_rocksdb = NULL;
	if (this->_storage->get_type() == storage::type_rocksdb) {
		local_rocksdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	}
	if (local_rocksdb) {
		op_meta* meta_op = new op_meta(this->_connection, NULL, NULL);
		log_info("checking if destination supports RocksDB WAL replication", 0);
		if (meta_op->run_client_features(peer_supports_wal, peer_master_id) < 0) {
			peer_supports_wal = false;
		}
		delete meta_op;
	}

	// Phase 2: incremental WAL push. This node is the replication
	// SOURCE (cluster_replication starts this handler only on a master
	// in mode=duplicate), so we stream OUR WAL delta to the
	// destination. Incremental sync is only meaningful when the
	// destination already follows our lineage — i.e. it was previously
	// seeded by a full dump from this node (or from the same lineage).
	if (local_rocksdb && peer_supports_wal) {
		string local_master_id = local_rocksdb->get_master_id();
		if (peer_master_id == local_master_id) {
			this->_thread->set_op("repl_sync_wal");
			log_info("attempting incremental WAL push (master_id=%s)", local_master_id.c_str());

			op_repl_sync_wal* wal_op = new op_repl_sync_wal(this->_connection, this->_storage);

			// Streaming throttle: a RocksDB-specific WAL bandwidth /
			// interval of 0 inherits the cluster-wide reconstruction
			// settings, so operators who don't need phase-specific
			// tuning get sensible defaults automatically.
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

			int wal_result = wal_op->run_client_push(local_master_id);
			op_repl_sync_wal::client_result rc = wal_op->get_client_result();
			bool connection_dirty = wal_op->connection_dirty();
			delete wal_op;

			if (wal_result == 0 && rc == op_repl_sync_wal::client_success) {
				log_notice("WAL replication completed successfully (dest=%s:%d)",
					this->_replication_server_name.c_str(), this->_replication_server_port);
				this->_notify_resync_result(true);
				return 0;
			}

			switch (rc) {
				case op_repl_sync_wal::client_master_id_mismatch:
					log_warning("WAL push refused (master_id_mismatch) -> full dump", 0);
					break;
				case op_repl_sync_wal::client_lsn_ahead:
					log_warning("destination position ahead of local WAL (lsn_ahead) -> full dump to reset peer", 0);
					break;
				case op_repl_sync_wal::client_lsn_purged:
					log_notice("local WAL no longer covers destination position (lsn_purged) -> full dump to catch up", 0);
					break;
				default:
					log_warning("WAL replication failed (rc=%d), falling back to full dump replication", rc);
					break;
			}
			local_rocksdb->incr_wal_fallback_to_dump();

			// A failed exchange may have left protocol data on the
			// connection; reconnect before reusing it for op_set traffic.
			if (connection_dirty) {
				if (this->_reopen_connection() < 0) {
					this->_notify_resync_result(false);
					return -1;
				}
			}
			// Fall through to full dump replication
		} else {
			log_notice("destination follows a different lineage (dest=%s local=%s) -> full dump, then seed",
				peer_master_id.empty() ? "-" : peer_master_id.c_str(),
				local_rocksdb->get_master_id().c_str());
		}
	}

	// Capture the WAL position the dump will cover BEFORE the iteration
	// snapshot is created. Writes that land between this point and the
	// snapshot are both dumped and re-sent by the next WAL sync;
	// re-application is idempotent, whereas capturing the LSN after the
	// snapshot could silently skip updates.
	uint64_t seed_lsn = 0;
	if (local_rocksdb && peer_supports_wal) {
		seed_lsn = local_rocksdb->get_latest_sequence_number();
	}
#endif

	// Phase 3: Full dump replication (legacy mode or fallback)
	this->_thread->set_op("dump");

	if (this->_storage->iter_begin() < 0) {
		log_err("database busy", 0);
		this->_notify_resync_result(false);
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
	storage::entry e;
	storage::iteration i;
	bool dump_failed = false;
	while ((i = this->_storage->iter_next(e.key)) == storage::iteration_continue
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

		// replicate
		op_set* p = new op_set(this->_connection, NULL, NULL);
		if (p->run_client(e) < 0) {
			log_err("failed to replicate entry (key=%s) -> aborting dump", e.key.c_str());
			delete p;
			dump_failed = true;
			break;
		}

		delete p;

		// wait
		long elapsed_usec = this->_bwlimitter.sleep_for_bwlimit(e.size);
		if (wait > 0 && wait-elapsed_usec > 0) {
			log_debug("wait for %d usec", wait);
			usleep(wait-elapsed_usec);
		}
	}
	if (i == storage::iteration_error) {
		log_err("storage iteration failed during dump replication", 0);
		dump_failed = true;
	}

	this->_storage->iter_end();

	// A graceful shutdown request is neither a successful nor a failed
	// resync — record nothing so the failure streak reflects only real
	// outcomes.
	if (this->_thread && this->_thread->is_shutdown_request()) {
		this->_thread->set_state("shutdown");
		log_warning("dump replication interrupted (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%" PRIu64 ")",
				   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, this->_bwlimitter.get_bwlimit());
		return 0;
	}

	if (dump_failed) {
		log_err("dump replication failed (dest=%s:%d, partition=%d, partition_size=%d)",
				   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size);
		this->_notify_resync_result(false);
		return -1;
	}

	log_notice("dump replication completed (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%" PRIu64 ")",
			   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, this->_bwlimitter.get_bwlimit());

#ifdef HAVE_LIBROCKSDB
	// Phase 4: seed the destination with our lineage token and the WAL
	// position the dump covered, so the next resync can be incremental.
	// A seed failure is not a replication failure — the dump itself
	// succeeded; the next resync just falls back to a full dump again.
	if (local_rocksdb && peer_supports_wal) {
		op_repl_sync_wal* seed_op = new op_repl_sync_wal(this->_connection, this->_storage);
		if (seed_op->run_client_seed(local_rocksdb->get_master_id(), seed_lsn) < 0) {
			log_warning("failed to seed destination lineage; next resync will use a full dump", 0);
		}
		delete seed_op;
	}
#endif

	this->_notify_resync_result(true);
	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
void handler_dump_replication::_notify_resync_result(bool success) {
#ifdef HAVE_LIBROCKSDB
	// RocksDB resync accounting: after every attempt (WAL-incremental
	// or full-dump) record success/failure. If the streak of failures
	// reaches the configured threshold, ask the index to mark this
	// node `state_down` so clients are steered away while operators
	// investigate. The local RocksDB directory is left untouched, so
	// data is preserved and an operator can `up_node` after repair.
	// This path is a no-op for non-RocksDB backends.
	if (this->_storage->get_type() != storage::type_rocksdb) {
		return;
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rdb) {
		return;
	}
	uint64_t streak = rdb->notify_resync_result(success);
	if (!success) {
		log_warning("resync failure streak now %llu", (unsigned long long)streak);
		if (rdb->should_self_demote()) {
			log_err("resync failure threshold reached (%llu) -> self-demoting to state_down",
				(unsigned long long)streak);
			this->_cluster->request_down_node(
				this->_cluster->get_server_name(),
				this->_cluster->get_server_port());
		}
	}
#endif
}

int handler_dump_replication::_reopen_connection() {
	log_notice("reopening connection to %s:%d after unsynchronized WAL exchange",
		this->_replication_server_name.c_str(), this->_replication_server_port);
	shared_connection c(new connection_tcp(
			   this->_replication_server_name, this->_replication_server_port));
	if (c->open() < 0) {
		log_err("failed to reconnect to cluster replication server (name=%s, port=%d)",
				   this->_replication_server_name.c_str(), this->_replication_server_port);
		return -1;
	}
	this->_connection = c;
	return 0;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
