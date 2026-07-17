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
 *	handler_reconstruction.cc
 *
 *	implementation of gree::flare::handler_reconstruction
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "handler_reconstruction.h"
#include "connection_tcp.h"
#include "op_dump.h"
#include "op_meta.h"
#include "op_repl_sync_wal.h"

#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_reconstruction
 */
handler_reconstruction::handler_reconstruction(shared_thread t, cluster* cl, storage* st, string node_server_name, int node_server_port, int partition, int partition_size, cluster::role r, int reconstruction_interval, int reconstruction_bwlimit):
		thread_handler(t),
		_cluster(cl),
		_storage(st),
		_node_server_name(node_server_name),
		_node_server_port(node_server_port),
		_partition(partition),
		_partition_size(partition_size),
		_role(r),
		_reconstruction_interval(reconstruction_interval),
		_reconstruction_bwlimit(reconstruction_bwlimit) {
}

/**
 *	dtor for handler_reconstruction
 */
handler_reconstruction::~handler_reconstruction() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_reconstruction::run() {
	// Reconstruction failures are almost always transient in an orchestrated
	// cluster: the source is mid-promotion, mid-restart, or service DNS
	// still resolves to its previous pod IP (both observed on a live
	// cluster).
	// There is no external retry any more — the K8s operator rejects
	// deactivate_node and never re-issues a role shift for an unchanged
	// role — so a single failure used to strand the node in prepare
	// forever. Retry here with backoff; every attempt re-resolves and
	// reconnects from scratch.
	int result = -1;
	for (int attempt = 0; ; attempt++) {
		result = this->_run_once();
		if (result == 0) {
			return 0;
		}
		if (attempt >= 60) {
			break;
		}
		int delay = attempt < 4 ? (2 << attempt) : 30;	// 2,4,8,16,30,30,...
		log_notice("reconstruction attempt %d failed -> retrying in %d seconds (master=%s:%d, partition=%d)", attempt + 1, delay, this->_node_server_name.c_str(), this->_node_server_port, this->_partition);
		for (int i = 0; i < delay; i++) {
			if (this->_thread->is_shutdown_request()) {
				log_notice("shutdown requested -> abandoning reconstruction retry", 0);
				return -1;
			}
			sleep(1);
		}
	}
	// legacy behavior on FINAL failure only (flarei marks the node down;
	// the K8s operator rejects this and keeps the node in prepare).
	log_err("reconstruction failed permanently after retries -> deactivating node", 0);
	this->_cluster->deactivate_node();
	return result;
}

int handler_reconstruction::_run_once() {
	this->_thread->set_peer(this->_node_server_name, this->_node_server_port);
	this->_thread->set_state("connect");

	shared_connection c(new connection_tcp(this->_node_server_name, this->_node_server_port));
	this->_connection = c;
	if (c->open() < 0) {
		log_err("failed to connect to node server (name=%s, port=%d)", this->_node_server_name.c_str(), this->_node_server_port);
		return -1;
	}

	// WAL-first: when the local storage is RocksDB and we still hold a
	// consistent lineage with this master (matching master_id + a nonzero
	// last-applied LSN), try to catch up via incremental WAL sync instead
	// of a full dump. This is the common case after a slave pod restart on
	// a persistent volume: the DB (and its __flare_repl_last_lsn /
	// __flare_repl_master_id) survives, so only the delta needs shipping.
	// If it succeeds we skip the full dump and go straight to activation;
	// on any failure (or non-rocksdb / no prior lineage) via_wal stays
	// false and we fall through to the full dump, which merges (never
	// truncates) and is therefore always safe as a fallback.
	// _try_wal_reconstruction always probes the master's features first and
	// reports them back here (even when it declines WAL sync), so we can
	// seed the replication cursor after a full-dump fallback. peer_latest_lsn
	// is captured BEFORE the dump — see the ordering rationale in that method.
	bool peer_wal_supported = false;
	string peer_master_id;
	uint64_t peer_latest_lsn = 0;
	bool peer_reachable = false;
	bool via_wal = this->_try_wal_reconstruction(c, peer_wal_supported, peer_master_id, peer_latest_lsn, peer_reachable);

	if (!via_wal) {
#ifdef HAVE_LIBROCKSDB
		// Deletion propagation: op_dump only ships live keys, never
		// tombstones, and it MERGES into whatever is on disk. A replica
		// that was down while keys were deleted on the master would keep
		// those keys and, once Active, serve them (slaves serve reads) —
		// a stale-read resurrection. So for a SLAVE with a reachable live
		// source we replace local data with a clean truncate before the
		// full dump. Safe because:
		//  - the node is in Prepare with balance 0 for the whole
		//    reconstruction; it serves no reads until activation, so the
		//    empty window is never observable;
		//  - a crash mid-dump leaves it in Prepare and reconstruction
		//    re-runs — it was stale anyway, and an empty retry beats
		//    serving resurrected keys;
		//  - storage_rocksdb::truncate preserves the __flare_repl_master_id
		//    lineage token and resets __flare_repl_last_lsn to 0, which is
		//    exactly right — the post-dump seeding below re-seeds the LSN
		//    from the pre-dump probe (peer_latest_lsn);
		//  - it also clears any orphan keys left by a previous assignment.
		// tch/tcb keep the legacy merge behavior (no lineage/LSN machinery).
		//
		// TWO cases MUST NOT truncate, or we destroy the only good copy:
		//  1. MASTER reconstruction — a node being promoted to master may
		//     have NO live source (its predecessor is dead, which is why it
		//     is becoming master) and its local data may be the last copy.
		//     Truncating would wipe it and then dump nothing. Masters keep
		//     the legacy merge.
		//  2. Source unreachable — the pre-dump feature probe got no
		//     response, so the source is likely dead. The dump will fail
		//     too; leaving data intact lets the un-truncated retry preserve
		//     it instead of emptying the DB first.
		if (this->_storage->get_type() == storage::type_rocksdb) {
			//  3. Source not newer than us — the empty/stale-master trap.
			//     peer_reachable means the master ANSWERED, not that it has
			//     data. A master freshly rebuilt from an empty/wrong source
			//     reports latest_lsn 0 (truncate resets the cursor) while we
			//     may hold the real last copy at a higher LSN. Truncating to
			//     match it, then dumping its zero keys, destroys our data and
			//     PROPAGATES the emptiness to the next slave that rebuilds
			//     from us — the silent cascade observed on the dev cluster.
			//     Compare LSNs when the lineage matches (same master_id, so
			//     the counters are comparable) or when the source is simply
			//     empty (latest_lsn 0 is unambiguous regardless of lineage):
			//     if the source is not strictly newer than our local data,
			//     do NOT truncate. The un-truncated dump then merges the
			//     source's (nothing) into our data, preserving it; a genuine
			//     deletion-propagation resync has the master AHEAD of us and
			//     still truncates as before.
			storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
			uint64_t local_lsn = rdb ? rdb->get_repl_last_lsn() : 0;
			string local_master_id = rdb ? rdb->get_master_id() : "";
			bool same_lineage = rdb && !peer_master_id.empty()
				&& peer_master_id == local_master_id;
			bool source_not_newer = local_lsn > 0
				&& (peer_latest_lsn == 0 || (same_lineage && peer_latest_lsn < local_lsn));

			if (this->_role != cluster::role_slave) {
				log_notice("truncate skipped (master reconstruction — local data may be the last copy)", 0);
			} else if (!peer_reachable) {
				log_notice("truncate skipped (source unreachable)", 0);
			} else if (source_not_newer) {
				log_warning("truncate skipped: source is not newer than local data (source latest_lsn=%llu, local last_lsn=%llu, same_lineage=%d) — refusing to overwrite our copy with an emptier/staler master; merging instead", (unsigned long long)peer_latest_lsn, (unsigned long long)local_lsn, same_lineage ? 1 : 0);
			} else {
				log_notice("truncating local storage before full-dump reconstruction so deletions on the source propagate (WAL sync was unavailable; see previous log line)", 0);
				if (this->_storage->truncate(0) < 0) {
					log_err("failed to truncate storage before full dump", 0);
					return -1;
				}
			}
		}
#endif

		op_dump* p = new op_dump(c, this->_cluster, this->_storage);

		p->set_thread(this->_thread);
		this->_thread->set_state("execute");
		this->_thread->set_op(p->get_ident());

		log_notice("starting dump operation (master=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
				   this->_node_server_name.c_str(), this->_node_server_port, this->_partition, this->_partition_size, this->_cluster->get_reconstruction_interval(), this->_cluster->get_reconstruction_bwlimit());

		if (p->run_client(this->_reconstruction_interval, this->_partition, this->_partition_size, this->_reconstruction_bwlimit) < 0) {
			log_err("failed to reconstruct (%s %s)", op::result_cast(p->get_result()).c_str(), p->get_result_message().c_str());
			delete p;
			return -1;
		}

		delete p;
		log_notice("reconstruction via full dump completed (master=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
				   this->_node_server_name.c_str(), this->_node_server_port, this->_partition, this->_partition_size, this->_reconstruction_interval, this->_reconstruction_bwlimit);
	}

#ifdef HAVE_LIBROCKSDB
	// After a successful FULL DUMP reconstruction from an authoritative
	// master, adopt the master's identity token so that future WAL
	// incremental syncs against the same master succeed without being
	// refused by the mismatch check. Without this the node would trip
	// master_id_mismatch on every WAL attempt and burn cycles on
	// redundant full dumps. (Skipped when we reconstructed via WAL: the
	// lineage already matched by construction — that was a precondition.)
	// We reuse the master_id captured by _try_wal_reconstruction's pre-dump
	// probe rather than re-probing.
	if (!via_wal && this->_storage->get_type() == storage::type_rocksdb) {
		storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
		if (rdb) {
			if (!peer_master_id.empty()) {
				if (rdb->set_master_id(peer_master_id) == 0) {
					log_notice("adopted master_id=%s after reconstruction",
						peer_master_id.c_str());
				} else {
					log_warning("failed to persist adopted master_id", 0);
				}
			} else {
				log_info("peer did not advertise master_id; skipping lineage adoption", 0);
			}
		}
	}

	// Seed the replication cursor from the master's pre-dump latest_lsn so
	// the NEXT reconstruction can use incremental WAL sync. Runs after the
	// master_id adoption above so the lineage check inside passes.
	if (!via_wal) {
		this->_seed_repl_lsn_after_dump(c, peer_wal_supported, peer_latest_lsn);
	}
#endif

	// node activation (state -> ready)
	//
	// The activation op is as vital as the dump itself: if it is lost (a
	// single-shot send raced an index leader handover — observed live)
	// nothing else will ever flip this node out of prepare. The map keeps
	// saying prepare, the LOCAL state agrees, so even the activation
	// re-announce guard has nothing to re-announce; the node is parked
	// forever with a completed dataset. Retry with backoff and treat a
	// persistent failure as a failure of the whole attempt, so the outer
	// retry loop starts over.
	if (this->_role == cluster::role_master) {
		int n = this->_cluster->notify_master_reconstruction();
		log_notice("master reconstruction completed (%d threads left)", n);
		if (n <= 0) {
			if (this->_activate_with_retry(false) < 0) {
				return -1;
			}
			this->_cluster->set_activation_pending(true);
		}
	} else {
		// just shift state to ready
		if (this->_activate_with_retry(true) < 0) {		// true: skip ready state
			return -1;
		}
		// Mark the ack as provisional until a node map echoes it back: an
		// ack from a leader that dies before persisting is worth nothing,
		// and neither the retry (op succeeded) nor the local-active
		// re-announce (local state never flipped) can recover it. The
		// map-side anti-entropy in cluster::reconstruct_node clears this
		// once an accepted map shows us out of prepare.
		this->_cluster->set_activation_pending(true);
	}

	return 0;
}

/**
 *	activate_node with bounded retry (see the activation comment in
 *	_run_once). ~1 minute of attempts covers any realistic index leader
 *	handover; shutdown requests abort immediately.
 */
int handler_reconstruction::_activate_with_retry(bool skip_ready_state) {
	int rc = -1;
	for (int i = 0; i < 30; i++) {
		rc = this->_cluster->activate_node(skip_ready_state);
		if (rc == 0) {
			return 0;
		}
		log_warning("node activation failed (attempt %d) -> retrying in 2 seconds", i + 1);
		for (int j = 0; j < 2; j++) {
			if (this->_thread->is_shutdown_request()) {
				log_notice("shutdown requested -> abandoning activation retry", 0);
				return -1;
			}
			sleep(1);
		}
	}
	log_err("node activation failed permanently after retries", 0);
	return rc;
}
// }}}

// {{{ protected methods
/**
 *	Attempt WAL-based incremental reconstruction against the master.
 *
 *	Always probes the master's features FIRST and reports them back via the
 *	out-params (peer_wal_supported / peer_master_id / peer_latest_lsn), even
 *	when it then declines to run WAL sync — the caller needs peer_latest_lsn
 *	to seed the replication cursor after a full-dump fallback. CRITICAL: this
 *	probe must run BEFORE the dump so the captured latest_lsn is the master's
 *	sequence number as of *before* the dump snapshot. Seeding a pre-dump LSN
 *	makes the next WAL sync replay a small overlapping suffix (harmless —
 *	RocksDB WAL batches carry resolved absolute Puts, so re-applying them is
 *	idempotent and converges), whereas a post-dump LSN could SKIP writes the
 *	dump snapshot missed and silently lose data.
 *
 *	Returns true only if the full delta was applied via WAL sync (caller
 *	skips the dump). Returns false — safely — in every other case: non-rocksdb
 *	storage, peer without WAL support, no prior lineage (empty/mismatched
 *	master_id or LSN 0), or any classified WAL failure. On a classified WAL
 *	failure the wal_fallback_to_dump counter is bumped and the caller proceeds
 *	to the non-destructive full dump.
 *
 *	Gating is deliberately strict: we only trust the local WAL cursor when
 *	the master identity token still matches the peer's, so a node restored
 *	from a backup, resynced against a different cluster, or freshly created
 *	always full-dumps rather than risk applying an incompatible WAL stream.
 */
bool handler_reconstruction::_try_wal_reconstruction(shared_connection c,
		bool& peer_wal_supported, string& peer_master_id, uint64_t& peer_latest_lsn,
		bool& peer_reachable) {
	peer_wal_supported = false;
	peer_master_id.clear();
	peer_latest_lsn = 0;
	peer_reachable = false;
#ifdef HAVE_LIBROCKSDB
	if (this->_storage->get_type() != storage::type_rocksdb) {
		return false;
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rdb) {
		return false;
	}

	// Probe the master's capabilities, lineage, and current LSN FIRST —
	// before any dump — and hand the results back to the caller so the
	// full-dump fallback can seed its cursor from peer_latest_lsn. A
	// meta_rc of 0 means the source answered (it is alive), which the
	// caller needs to decide whether truncating before the dump is safe:
	// truncating and then dumping from a DEAD source yields an empty DB.
	{
		op_meta* meta = new op_meta(c, NULL, this->_storage);
		int meta_rc = meta->run_client_features(peer_wal_supported, peer_master_id, peer_latest_lsn);
		delete meta;
		peer_reachable = (meta_rc == 0);
		if (meta_rc != 0 || !peer_wal_supported) {
			log_info("master does not support WAL replication -> full dump", 0);
			return false;
		}
	}

	// A nonzero last-applied LSN is the whole precondition for incremental
	// catch-up: without it there is nothing to be incremental from. (This
	// is the chicken-and-egg case a fresh full-dump slave hits — it will
	// now be seeded from peer_latest_lsn after the dump so the NEXT sync
	// can go incremental.)
	uint64_t last_lsn = rdb->get_repl_last_lsn();
	string local_master_id = rdb->get_master_id();
	if (last_lsn == 0 || local_master_id.empty()) {
		log_info("WAL reconstruction skipped (last_lsn=%llu, master_id=%s) -> full dump",
			(unsigned long long)last_lsn, local_master_id.c_str());
		return false;
	}

	// Strict lineage check: only proceed if our remembered master identity
	// matches the peer's. Any mismatch (or a peer that does not advertise
	// one) means our WAL cursor is not comparable to theirs.
	if (peer_master_id.empty() || peer_master_id != local_master_id) {
		log_notice("WAL reconstruction refused: master_id mismatch (local=%s peer=%s) -> full dump",
			local_master_id.c_str(), peer_master_id.c_str());
		return false;
	}

	this->_thread->set_state("execute");
	this->_thread->set_op("repl_sync_wal");
	log_notice("attempting reconstruction via WAL incremental sync (master=%s:%d, lsn=%llu, master_id=%s)",
		this->_node_server_name.c_str(), this->_node_server_port,
		(unsigned long long)last_lsn, local_master_id.c_str());

	op_repl_sync_wal* wal_op = new op_repl_sync_wal(c, this->_storage);

	// Throttling: a RocksDB-specific WAL bandwidth/interval of 0 inherits
	// the cluster-wide reconstruction settings (mirrors
	// handler_dump_replication).
	wal_op->set_max_batch_bytes(rdb->get_wal_max_batch_bytes());
	int wal_bwlimit = rdb->get_wal_sync_bwlimit();
	if (wal_bwlimit == 0) {
		wal_bwlimit = this->_reconstruction_bwlimit;
	}
	int wal_interval = rdb->get_wal_sync_interval();
	if (wal_interval == 0) {
		wal_interval = this->_reconstruction_interval;
	}
	wal_op->set_wal_sync_bwlimit(wal_bwlimit);
	wal_op->set_wal_sync_interval(wal_interval);

	int wal_result = wal_op->run_client(last_lsn, local_master_id);
	op_repl_sync_wal::client_result rc = wal_op->get_client_result();
	delete wal_op;

	if (wal_result == 0 && rc == op_repl_sync_wal::client_success) {
		log_notice("reconstruction via WAL incremental sync completed (master=%s:%d, from_lsn=%llu, now_lsn=%llu)",
			this->_node_server_name.c_str(), this->_node_server_port,
			(unsigned long long)last_lsn, (unsigned long long)rdb->get_repl_last_lsn());
		return true;
	}

	const char* reason = "error";
	switch (rc) {
		case op_repl_sync_wal::client_master_id_mismatch: reason = "master_id_mismatch"; break;
		case op_repl_sync_wal::client_lsn_ahead:          reason = "lsn_ahead"; break;
		case op_repl_sync_wal::client_lsn_purged:         reason = "lsn_purged"; break;
		default:                                          reason = "error"; break;
	}
	log_notice("WAL incremental sync failed (reason=%s) -> falling back to full dump", reason);
	rdb->incr_wal_fallback_to_dump();
	return false;
#else
	(void)c;
	return false;
#endif
}

void handler_reconstruction::_seed_repl_lsn_after_dump(shared_connection c,
		bool peer_wal_supported, uint64_t peer_latest_lsn) {
#ifdef HAVE_LIBROCKSDB
	// Seed the replication cursor after a full-dump reconstruction so the
	// NEXT reconstruction can go incremental (WAL). Only when: rocksdb
	// backend, the peer advertised WAL support, it reported a nonzero
	// latest_lsn, and — critically — our master_id now matches the peer's
	// (the adoption step just ran). The seeded LSN is the master's *pre-
	// dump* sequence number (captured in _try_wal_reconstruction before the
	// dump); replaying that small overlap on the next sync is idempotent
	// because RocksDB WAL batches are absolute Puts. A post-dump LSN is
	// deliberately NOT used: it could skip writes the snapshot missed.
	if (!peer_wal_supported || peer_latest_lsn == 0) {
		return;
	}
	if (this->_storage->get_type() != storage::type_rocksdb) {
		return;
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rdb) {
		return;
	}
	if (rdb->get_master_id().empty()) {
		// Lineage adoption did not succeed; seeding an LSN against an
		// unknown master would be unsafe. Skip — next time we full-dump.
		log_info("skip repl_lsn seeding: no master_id after dump", 0);
		return;
	}
	if (rdb->set_repl_last_lsn(peer_latest_lsn) == 0) {
		log_notice("seeded repl_last_lsn=%llu after full dump (enables incremental WAL on next sync)",
			(unsigned long long)peer_latest_lsn);
	}
#else
	(void)c;
	(void)peer_wal_supported;
	(void)peer_latest_lsn;
#endif
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
