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
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <boost/bind.hpp>
#include "app.h"
#include "connection_tcp.h"
#include "op_dump.h"
#include "op_meta.h"
#include "op_repl_sync_wal.h"
#include "copy_protection.h"
#include "op_repl_snapshot.h"
#include "copy_capacity.h"

#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#include "copy_switch_fs.h"
#endif
#include <sstream>

namespace gree {
namespace flare {

namespace {
/**
 *	A connection to a replication source with a CONNECT DEADLINE (3 s, one
 *	retry): a source pod that vanished without a RST must not block an
 *	attempt for the kernel's SYN timeout (CI 37407630865).
 */
shared_connection bounded_connection(const string& host, int port, int read_timeout_ms = 30000) {
	connection_tcp* t = new connection_tcp(host, port);
	t->set_connect_timeout_ms(3000);
	t->set_connect_retry_limit(1);
	// Explicit, not inherited: the process-wide default is 600 s outside
	// the K8s build. A source that accepts the connection and never answers
	// must not hold an attempt either.
	t->set_read_timeout(read_timeout_ms);
	return shared_connection(t);
}
}	// namespace

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
		_copy_dirty(false),
		_force_clean(false),
		_attempt_master_id(""),
		_identity_known(false),
		_epoch_supported(false),
		_pending_activation(false),
		_partition(partition),
		_partition_size(partition_size),
		_role(r),
		_reconstruction_interval(reconstruction_interval),
		_reconstruction_bwlimit(reconstruction_bwlimit),
		_reconstruction_id(0) {
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
	// R3: a new copy is being taken; no previous validation carries over.
	if (this->_role == cluster::role_slave) {
		this->_cluster->reset_read_source("reconstruction started (partition " + boost::lexical_cast<string>(this->_partition) + ")");
	}
	// One request = one handler = one reconstruction id; retries inside do
	// not start a new one. The completion record (id, state, source) is what
	// a controller reads: cumulative counters cannot tell a failed-then-
	// succeeded pair from one in flight.
	if (stats_object != NULL) {
		this->_reconstruction_id = stats_object->reconstruction_begin();
	}
	char source[BUFSIZ];
	snprintf(source, sizeof(source), "%s:%d", this->_node_server_name.c_str(), this->_node_server_port);
	for (int attempt = 0; ; attempt++) {
		// RE-SELECT THE SOURCE every attempt (a slave's source is its
		// partition's master in the CURRENT map). A handler that kept the
		// source it was created with retried a drained ex-master for up to
		// ~30 min and could dump from it after it came back as a non-master
		// (CI 37386580971, empty-source test 4).
		if (this->_role == cluster::role_slave) {
			const string cur = this->_cluster->get_partition_master_key(this->_partition);
			const string was = this->_cluster->to_node_key(this->_node_server_name, this->_node_server_port);
			if (cur.empty()) {
				log_notice("reconstruction attempt %d: partition %d has no master in the current map -> waiting (source unknown%s)", attempt + 1, this->_partition,
					this->_pending_activation ? "; the completed copy is kept" : ", nothing copied");
				result = -1;
			} else if (cur == this->_cluster->get_own_node_key()) {
				log_notice("reconstruction abandoned: this node is now the master of partition %d (the role change starts what it needs)", this->_partition);
				return -1;
			} else {
				if (cur != was) {
					string host;
					int port = 0;
					this->_cluster->from_node_key(cur, host, port);
					log_warning("reconstruction source changed: %s -> %s (attempt %d); any partial copy from the previous source is discarded before the new one is copied", was.c_str(), cur.c_str(), attempt + 1);
					this->_node_server_name = host;
					this->_node_server_port = port;
					snprintf(source, sizeof(source), "%s:%d", host.c_str(), port);
					if (this->_copy_dirty) {
						this->_force_clean = true;
					}
					// a completed copy from the previous source is dropped
					this->_pending_activation = false;
				}
				if (this->_pending_activation) {
					// COMPLETED copy awaiting validation: re-validate and
					// activate only; never a new transfer while Unknown.
					const int pr = this->_activate_pending();
					result = (pr == 0) ? 0 : -1;
				} else {
					result = this->_run_once();
				}
			}
		} else {
			result = this->_run_once();
		}
		if (result == 0) {
			if (stats_object != NULL) {
				stats_object->reconstruction_succeeded_from(this->_reconstruction_id, string(source));
			}
			return 0;
		}
#ifdef HAVE_LIBROCKSDB
		// PARKED (design §10): a blocked staged rebuild waits for the
		// operator's rebuild_resume; it is not a failed attempt and does not
		// run toward the give-up below (a resume would then find no handler)
		{
			storage_rocksdb* prdb = dynamic_cast<storage_rocksdb*>(this->_storage);
			if (prdb != NULL && prdb->is_rebuild_parked()) {
				log_notice("reconstruction PARKED (rebuild_blocked=%s): no transfer and no retry until the operator resumes it (rebuild_resume)", prdb->get_rebuild_blocked().c_str());
				while (prdb->is_rebuild_parked()) {
					if (this->_thread->is_shutdown_request()) {
						log_notice("shutdown requested while parked -> abandoning reconstruction", 0);
						if (stats_object != NULL) {
							stats_object->reconstruction_aborted_by_shutdown(this->_reconstruction_id);
						}
						return -1;
					}
					sleep(1);
				}
				attempt = -1;		// a fresh attempt after the resume
				continue;
			}
		}
#endif
		if (attempt >= 60) {
			break;
		}
		int delay = attempt < 4 ? (2 << attempt) : 30;	// 2,4,8,16,30,30,...
		log_notice("reconstruction attempt %d failed -> retrying in %d seconds (master=%s:%d, partition=%d)", attempt + 1, delay, this->_node_server_name.c_str(), this->_node_server_port, this->_partition);
		for (int i = 0; i < delay; i++) {
			if (this->_thread->is_shutdown_request()) {
				log_notice("shutdown requested -> abandoning reconstruction retry", 0);
				if (stats_object != NULL) {
					stats_object->reconstruction_aborted_by_shutdown(this->_reconstruction_id);
				}
				return -1;
			}
			sleep(1);
		}
	}
	// legacy behavior on FINAL failure only (flarei marks the node down;
	// the K8s operator rejects this and keeps the node in prepare).
	log_err("reconstruction failed permanently after retries -> deactivating node", 0);
	if (stats_object != NULL) {
		stats_object->reconstruction_failed_final(this->_reconstruction_id);
	}
	this->_cluster->deactivate_node();
	return result;
}

int handler_reconstruction::_run_once() {
	this->_thread->set_peer(this->_node_server_name, this->_node_server_port);
	this->_thread->set_state("connect");
	// TEST SEAM: a stop point at the START of the attempt too, before any
	// decision (catch-up, merge-or-truncate, snapshot), so a test can change
	// the source while the whole attempt waits (a slave only)
	if (this->_role == cluster::role_slave && !this->_test_hold("FLARE_TEST_RECONSTRUCTION_START_HOLD_FILE", "reconstruction start")) {
		return -1;
	}

#ifdef HAVE_LIBROCKSDB
	// CORRUPTION SELF-HEAL: a poisoned local DB rejects the truncate that
	// precedes a full dump (and even the WAL apply), so an ordinary
	// reconstruction retries forever ("failed to truncate ... Corruption",
	// observed live twice). We are ALREADY a slave being reconstructed here
	// (balance 0, serving nothing), so wiping is safe — do the in-process
	// Case-A once up front, then reseed onto the clean empty DB. Never for a
	// master reconstruction: its data may be the last surviving copy.
	if (this->_role == cluster::role_slave
			&& this->_storage->get_type() == storage::type_rocksdb) {
		storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
		if (rdb && rdb->is_corrupted()) {
			// R3-D: an unreadable copy is not proof that nothing valuable is
			// in it — move it aside, never delete it; if it cannot be moved,
			// stop (nothing is deleted)
			string moved_to;
			log_warning("local storage is corrupted -> moving it aside (quarantine) before reseed", 0);
			if (rdb->quarantine_reset(moved_to) < 0) {
				log_err("CRITICAL: the corrupt copy could not be moved aside; NOT deleting it and NOT reconstructing (operator action needed)", 0);
				return -1;
			}
		}
	}
#endif

	shared_connection c(bounded_connection(this->_node_server_name, this->_node_server_port));
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
	bool peer_snapshot_supported = false;
	bool via_wal = this->_try_wal_reconstruction(c, peer_wal_supported, peer_master_id, peer_latest_lsn, peer_reachable, peer_snapshot_supported);
	this->_attempt_master_id = peer_master_id;

	// the copy was replaced by a verified staging copy (design §3)
	bool via_staging = false;

	if (!via_wal) {
#ifdef HAVE_LIBROCKSDB
		// Whatever this copy was rebuilt from before, it is about to change
		// (snapshot swap, truncate + dump, or a merge dump): drop the rebuild
		// evidence FIRST and durably, so a failure, a source change or a
		// restart part-way leaves none. If it cannot be dropped, do not
		// rebuild (the stale evidence would outlive a partial copy).
		if (this->_storage->get_type() == storage::type_rocksdb) {
			storage_rocksdb* erdb = dynamic_cast<storage_rocksdb*>(this->_storage);
			// R3-D: the advertised evidence is withdrawn, but kept durably as
			// the evidence of the STORED copy (survives a restart) until that
			// copy changes; the protection rule judges the copy by it
			if (erdb && erdb->suspend_rebuilt_from() < 0) {
				log_err("could not withdraw the rebuild evidence before rebuilding -> not rebuilding this cycle", 0);
				return -1;
			}
		}
		// Deletion propagation: op_dump only ships live keys, never
		// tombstones, and it MERGES into whatever is on disk. A replica
		// that was down while keys were deleted on the master would keep
		// those keys and, once Active, serve them (slaves serve reads) —
		// a stale-read resurrection. So for a SLAVE with a reachable live
		// source the copy is REPLACED: since copy retention (design §3) the
		// replacement is built in a staging copy next to this one, verified
		// and switched in, and this copy is retained — it is never truncated
		// or discarded first. tch/tcb keep the legacy merge behavior (no
		// lineage/LSN machinery).
		//
		// THREE cases do not replace the copy (they merge into it):
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
				log_notice("copy not replaced (master reconstruction — local data may be the last copy): merging", 0);
			} else if (!peer_reachable) {
				log_notice("copy not replaced (source unreachable): merging", 0);
			} else if (source_not_newer && !this->_force_clean) {
				log_warning("truncate skipped: source is not newer than local data (source latest_lsn=%llu, local last_lsn=%llu, same_lineage=%d) — refusing to overwrite our copy with an emptier/staler master; merging instead", (unsigned long long)peer_latest_lsn, (unsigned long long)local_lsn, same_lineage ? 1 : 0);
			} else {
				// Exactly the conditions under which this replica's copy is
				// replaced (slave, source reachable and strictly newer, or a
				// clean rebuild after a source change). COPY RETENTION (design
				// §3): the replacement is built NEXT TO this copy, verified and
				// switched in; this copy is retained, never truncated or
				// discarded first. No room, no reserve, or an unverifiable
				// source: the rebuild STOPS and says why (stats rebuild_blocked).
				// TEST SEAM (E2E only): force the full-dump path.
				const char* no_snap = getenv("FLARE_TEST_DISABLE_SNAPSHOT_BOOTSTRAP");
				if (peer_snapshot_supported && no_snap != NULL && no_snap[0] != '\0' && strcmp(no_snap, "0") != 0) {
					log_warning("snapshot bootstrap disabled by FLARE_TEST_DISABLE_SNAPSHOT_BOOTSTRAP (test seam) -> staged full dump", 0);
					peer_snapshot_supported = false;
				}
				// (the live copy changes only at the switch: _staged_rebuild
				// marks it dirty there, never for a stopped or abandoned attempt)
				if (this->_staged_rebuild(peer_snapshot_supported, peer_master_id, peer_latest_lsn, peer_wal_supported) < 0) {
					return -1;
				}
				via_staging = true;
				this->_force_clean = false;
			}
		}
#endif

		if (!via_staging) {
		// a MERGING dump (see above: master, unreachable or not-newer source)
		// FRESH connection for the dump as well: `c` may carry residue from
		// an aborted WAL stream (see the snapshot rationale above), and
		// op_dump's streamed VALUE parsing is just as offset-sensitive.
		{
			shared_connection cd(bounded_connection(this->_node_server_name, this->_node_server_port));
			if (cd->open() < 0) {
				log_err("failed to open a fresh connection for the full dump (name=%s, port=%d)", this->_node_server_name.c_str(), this->_node_server_port);
				return -1;
			}
			c = cd;
			this->_connection = c;
		}
		this->_copy_dirty = true;
#ifdef HAVE_LIBROCKSDB
		// R3-D: a MERGING dump (no truncate) changes the stored copy too; its
		// suspended evidence no longer describes it
		if (this->_storage->get_type() == storage::type_rocksdb) {
			storage_rocksdb* mrdb = dynamic_cast<storage_rocksdb*>(this->_storage);
			if (mrdb != NULL) mrdb->clear_suspended_rebuilt_from();
		}
#endif
#ifdef HAVE_LIBROCKSDB
		// decision 2026-10-08: a merging dump changes the live copy key by
		// key. The PARTIAL marker is durable BEFORE the first change and is
		// removed only once the dump completed (END) and its follow-up
		// (lineage, cursor) is recorded: a copy left part-way (failure, crash)
		// is never promoted, not even as a last resort.
		if (this->_storage->get_type() == storage::type_rocksdb) {
			storage_rocksdb* prdb = dynamic_cast<storage_rocksdb*>(this->_storage);
			if (prdb != NULL && prdb->mark_copy_partial("merging full dump") < 0) {
				log_err("the partial-copy marker could not be written -> not changing the copy", 0);
				return -1;
			}
		}
#endif
		op_dump* p = new op_dump(c, this->_cluster, this->_storage);
		// every key must be stored and the END marker seen (else partial)
		p->set_strict(true);

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
		}	// !via_staging
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
	if (!via_wal && !via_staging && this->_storage->get_type() == storage::type_rocksdb) {
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

	// REBUILD EVIDENCE is recorded only by the staged path (a verified
	// replacement, _staged_rebuild); a merging dump carries none.

	// Seed the replication cursor from the master's pre-dump latest_lsn so
	// the NEXT reconstruction can use incremental WAL sync. Runs after the
	// master_id adoption above so the lineage check inside passes.
	if (!via_wal && !via_staging) {
		this->_seed_repl_lsn_after_dump(c, peer_wal_supported, peer_latest_lsn);
		// the merging dump completed and its follow-up is recorded
		if (this->_storage->get_type() == storage::type_rocksdb) {
			storage_rocksdb* prdb = dynamic_cast<storage_rocksdb*>(this->_storage);
			if (prdb != NULL) prdb->clear_copy_partial("merging full dump completed");
		}
	}
#endif

	// node activation (state -> ready)
	//
	// The activation op is as vital as the dump itself: if it is lost (a
	// single-shot send raced an index leader handover — observed live)
	// nothing else will ever flip this node out of prepare. Retry with
	// backoff. A MASTER reconstruction keeps the old behaviour (a failure
	// fails the attempt). A SLAVE copy is now COMPLETE: it enters the
	// pending-activation state, and from here on the retries re-validate
	// and re-activate it — they do not copy again unless the source CHANGED.
	if (this->_role == cluster::role_master) {
		int n = this->_cluster->notify_master_reconstruction();
		log_notice("master reconstruction completed (%d threads left)", n);
		if (n <= 0) {
			if (this->_activate_with_retry(false) < 0) {
				return -1;
			}
			this->_cluster->set_activation_pending(true);
		}
		return 0;
	}
	this->_pending_activation = true;
	return this->_activate_pending();
}

int handler_reconstruction::_activate_pending() {
	const int rc = this->_activate_with_retry(true);		// true: skip ready state
	if (rc == 0) {
		this->_pending_activation = false;
		// Mark the ack as provisional until a node map echoes it back: an
		// ack from a leader that dies before persisting is worth nothing,
		// and neither the retry (op succeeded) nor the local-active
		// re-announce (local state never flipped) can recover it. The
		// map-side anti-entropy in cluster::reconstruct_node clears this
		// once an accepted map shows us out of prepare.
		this->_cluster->set_activation_pending(true);
		return 0;
	}
	if (rc == -2) {
		this->_pending_activation = false;
		this->_force_clean = true;
		return -2;
	}
	if (rc == -3) {
		this->_pending_activation = false;
		return -3;
	}
	return -1;		// still pending: the copy is kept
}

/**
 *	Is the copy's source still valid for activation? See the declaration.
 */
handler_reconstruction::source_check handler_reconstruction::_check_source(string& why) {
	if (this->_role != cluster::role_slave) {
		return source_valid;		// a master's reconstruction is not tied to one source
	}
	const string cur = this->_cluster->get_partition_master_key(this->_partition);
	const string src = this->_cluster->to_node_key(this->_node_server_name, this->_node_server_port);
	if (cur.empty()) {
		why = "the partition has no master in the current map (Unknown: copy kept, checked again)";
		return source_unknown;
	}
	if (cur != src) {
		why = "the partition's master is now " + cur + ", not the source " + src;
		return source_changed;
	}
	if (this->_storage->get_type() != storage::type_rocksdb) {
		return source_valid;		// no lineage/epoch to compare on this backend
	}
	// What the copy can be validated against is what was ESTABLISHED when it
	// was taken. An incomplete copy-time probe is not "nothing to compare".
	if (!this->_identity_known) {
		why = "the source's identity was not established when this copy was taken (incomplete probe): the copy cannot be validated";
		return source_copy_unverified;
	}
	if (this->_epoch_supported && this->_probe_source_epoch.empty()) {
		why = "the source answered without a source epoch value when this copy was taken (generations unavailable): the copy cannot be validated";
		return source_copy_unverified;
	}
	// Identity probe: connect deadline 3 s, per-read 5 s, and a TOTAL
	// deadline of 8 s for the whole request (a peer that trickles bytes).
	shared_connection c(bounded_connection(this->_node_server_name, this->_node_server_port, 5000));
	if (c->open() < 0) {
		why = "the source " + src + " cannot be reached (Unknown: copy kept, checked again)";
		return source_unknown;
	}
	connection_tcp* ct = dynamic_cast<connection_tcp*>(c.get());
	if (ct != NULL) {
		ct->set_deadline_from_now(8000);
	}
	op_meta* meta = new op_meta(c, NULL, this->_storage);
	bool wal = false;
	string id;
	uint64_t lsn = 0;
	const int rc = meta->run_client_features(wal, id, lsn);
	const string epoch = meta->get_peer_source_epoch();
	const bool epoch_token = meta->get_peer_epoch_token();
	delete meta;
	if (rc != 0 || !wal || id.empty()) {
		why = "the source " + src + " did not give a complete identity reply (Unknown: copy kept, checked again)";
		return source_unknown;
	}
	if (id != this->_attempt_master_id) {
		why = "the source " + src + " changed lineage (master_id " + this->_attempt_master_id + " -> " + id + ")";
		return source_changed;
	}
	if (this->_epoch_supported) {
		if (!epoch_token || epoch.empty()) {
			why = "the source " + src + " answered without its source epoch (Unknown: copy kept, checked again)";
			return source_unknown;
		}
		if (epoch != this->_probe_source_epoch) {
			why = "the source " + src + " changed history (source epoch " + this->_probe_source_epoch + " -> " + epoch + ")";
			return source_changed;
		}
		return source_valid;
	}
	// LEGACY COMPATIBILITY (recorded as a weaker guarantee): the copy-time
	// reply was COMPLETE and carried no source_epoch token at all — an older
	// flared. Only the lineage can be compared; a re-promotion of the same
	// lineage is not detected on this path.
	log_notice("source %s predates source epochs: validated by lineage only (weaker than the history check)", src.c_str());
	return source_valid;
}


/**
 *	R3-D: read the source's item count and identity with one bounded `stats`
 *	request (3 s connect, 5 s per read, 8 s in total). Anything incomplete
 *	leaves `out.known` false (Unknown).
 */
void handler_reconstruction::probe_source_identity(const string& host, int port, copy_identity& out) {
	out = copy_identity();
	connection_tcp* t = new connection_tcp(host, port);
	t->set_connect_timeout_ms(3000);
	t->set_connect_retry_limit(1);
	t->set_read_timeout(5000);
	shared_connection c(t);
	if (c->open() < 0) {
		return;
	}
	t->set_deadline_from_now(8000);
	const char* req = "stats\r\n";
	if (c->write(req, strlen(req)) < 0) {
		return;
	}
	bool ended = false;
	bool items_seen = false;
	bool copy_bytes_seen = false;
	for (int i = 0; i < 2000; i++) {
		char* p = NULL;
		if (c->readline(&p) < 0) {
			break;
		}
		string line(p);
		delete[] p;
		while (!line.empty() && (line[line.size() - 1] == '\n' || line[line.size() - 1] == '\r')) {
			line.erase(line.size() - 1);
		}
		if (line == "END") {
			ended = true;
			break;
		}
		if (line.compare(0, 5, "STAT ") != 0) {
			continue;
		}
		const string rest = line.substr(5);
		const size_t sp = rest.find(' ');
		if (sp == string::npos) {
			continue;
		}
		const string key = rest.substr(0, sp);
		const string value = rest.substr(sp + 1);
		if (key == "curr_items") {
			try {
				out.items = boost::lexical_cast<uint64_t>(value);
				items_seen = true;
			} catch (boost::bad_lexical_cast&) {
				return;
			}
		} else if (key == "rocksdb_master_id") {
			out.lineage = value;
		} else if (key == "rocksdb_source_epoch") {
			out.epoch = value;
		} else if (key == "rocksdb_source_epoch_reason") {
			out.epoch_reason = value;
		} else if (key == "rocksdb_copy_bytes" || (key == "data_dir_used_bytes" && !copy_bytes_seen)) {
			try {
				out.copy_bytes = boost::lexical_cast<uint64_t>(value);
				out.size_known = true;
				if (key == "rocksdb_copy_bytes") copy_bytes_seen = true;
			} catch (boost::bad_lexical_cast&) {
			}
		}
	}
	out.known = ended && items_seen;
	if (!ended) out.size_known = false;
}

/**
 *	R3-D: the protection rule, evaluated right before a destructive step on
 *	this slave's copy. Never cached: every step evaluates it again against the
 *	source and the copy as they are now. The test stop point holds BEFORE the
 *	evaluation, so a test can change the source while it holds.
 */
copy_gate handler_reconstruction::_copy_gate(const char* step, string& why, bool strict) {
	// TEST SEAM (E2E only): hold before the evaluation while the file exists
	if (!this->_test_hold("FLARE_TEST_DESTRUCTIVE_HOLD_FILE", step)) {
		why = "shutdown requested while held";
		return gate_refuse_unknown;
	}
	copy_identity local;
	local.items = this->_storage->count();
	local.known = true;
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb != NULL) {
		if (rdb->is_corrupted()) {
			local.known = false;	// an unreadable copy is not an empty one
		}
		local.lineage = rdb->get_master_id();
		local.epoch = rdb->get_source_epoch();
		// the evidence of the STORED copy: suspended while a rebuild is in
		// progress (persisted, so a restart does not lose it), otherwise the
		// advertised one
		local.rebuilt_from_lineage = rdb->get_suspended_rebuilt_from_master_id();
		local.rebuilt_from_epoch = rdb->get_suspended_rebuilt_from_epoch();
		if (local.rebuilt_from_lineage.empty() || local.rebuilt_from_epoch.empty()) {
			local.rebuilt_from_lineage = rdb->get_rebuilt_from_master_id();
			local.rebuilt_from_epoch = rdb->get_rebuilt_from_epoch();
		}
	}
#endif
	copy_identity source;
	handler_reconstruction::probe_source_identity(this->_node_server_name, this->_node_server_port, source);
	copy_gate g = decide_copy_gate(local, source, why);
	if (strict && g == gate_allow && source.items == 0) {
		why += "; but this step discards the copy BEFORE the replacement exists, which needs a source that holds keys";
		g = gate_refuse_unsafe;
	}
	const string src = this->_cluster->to_node_key(this->_node_server_name, this->_node_server_port);
	if (copy_gate_allows(g)) {
		log_notice("copy protection '%s': %s — %s (source %s: %s%llu keys, epoch %s/%s; this copy: %llu keys, epoch %s, evidence %s)",
			step, copy_gate_name(g), why.c_str(), src.c_str(), source.known ? "" : "unknown, ", (unsigned long long)source.items,
			source.epoch.c_str(), source.epoch_reason.c_str(), (unsigned long long)local.items, local.epoch.c_str(), local.rebuilt_from_epoch.c_str());
	} else {
		log_warning("copy protection '%s': %s — %s (source %s: %s%llu keys, epoch %s/%s; this copy: %llu keys, epoch %s, evidence %s); the copy is KEPT and the reconstruction waits",
			step, copy_gate_name(g), why.c_str(), src.c_str(), source.known ? "" : "unknown, ", (unsigned long long)source.items,
			source.epoch.c_str(), source.epoch_reason.c_str(), (unsigned long long)local.items, local.epoch.c_str(), local.rebuilt_from_epoch.c_str());
	}
	return g;
}

bool handler_reconstruction::_test_hold(const char* env, const char* where) {
	const char* hold = getenv(env);
	struct stat st;
	bool held = false;
	while (hold != NULL && hold[0] != '\0' && stat(hold, &st) == 0) {
		if (!held) {
			log_warning("'%s' held by %s (test seam); evaluated after the release", where, env);
			held = true;
		}
		if (this->_thread->is_shutdown_request()) {
			return false;
		}
		sleep(1);
	}
	if (held) {
		log_notice("'%s' released (test seam)", where);
	}
	return true;
}

bool handler_reconstruction::_space_watch(string& why) {
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb == NULL) {
		why = "not a RocksDB storage";
		return false;
	}
	rdb->peaks_sample(false);
	if (capacity_watch_ok(rdb->get_rebuild_reserve_bytes(), rdb->rebuild_space_available(), why)) {
		return true;
	}
	rdb->set_rebuild_blocked("no_space");
	rdb->set_rebuild_parked(true);
	log_err("CRITICAL: rebuild_blocked=no_space — the staging copy is stopped before it eats into the reserve (%s); the live copy is KEPT", why.c_str());
	return false;
#else
	why = "not compiled with RocksDB";
	return false;
#endif
}

#ifdef HAVE_LIBROCKSDB
namespace {
	// One bounded features probe of the source: master_id, position, epoch.
	bool probe_position(const string& host, int port, storage* st, string& master_id, uint64_t& lsn, string& epoch) {
		master_id.clear();
		epoch.clear();
		lsn = 0;
		shared_connection c(bounded_connection(host, port, 5000));
		if (c->open() < 0) {
			return false;
		}
		op_meta* meta = new op_meta(c, NULL, st);
		bool wal = false;
		const int rc = meta->run_client_features(wal, master_id, lsn);
		epoch = meta->get_peer_source_epoch();
		delete meta;
		return rc == 0 && wal && !master_id.empty();
	}

	// Bring `target` from its cursor to at least `l1`, applying ONLY history
	// `epoch` (refused otherwise), contiguous and in order (a gap is refused
	// by the apply rule). Bounded: a slice that makes no progress fails.
	bool catch_up_to(const string& host, int port, storage_rocksdb* target, storage_rocksdb* settings,
			const string& master_id, const string& epoch, uint64_t l1, int bwlimit, int interval, string& why) {
		for (int round = 0; round < 1000; round++) {
			const uint64_t from = target->get_repl_last_lsn();
			if (from >= l1) {
				return true;
			}
			shared_connection c(bounded_connection(host, port));
			if (c->open() < 0) {
				why = "the source cannot be reached for the catch-up";
				return false;
			}
			op_repl_sync_wal* w = new op_repl_sync_wal(c, target);
			w->set_max_batch_bytes(settings->get_wal_max_batch_bytes());
			w->set_wal_sync_bwlimit(settings->get_wal_sync_bwlimit() != 0 ? settings->get_wal_sync_bwlimit() : bwlimit);
			w->set_wal_sync_interval(settings->get_wal_sync_interval() != 0 ? settings->get_wal_sync_interval() : interval);
			const int r = w->run_client_reconstruct(from, master_id, epoch);
			const op_repl_sync_wal::client_result cr = w->get_client_result();
			delete w;
			if (r != 0 || cr != op_repl_sync_wal::client_success) {
				ostringstream o;
				o << "the catch-up from " << from << " toward " << l1 << " failed (client result " << static_cast<int>(cr)
					<< (cr == op_repl_sync_wal::client_lsn_purged ? ": purged history" : "")
					<< (cr == op_repl_sync_wal::client_no_epoch || cr == op_repl_sync_wal::client_epoch_mismatch ? ": another history" : "") << ")";
				why = o.str();
				return false;
			}
			if (target->get_repl_last_lsn() <= from) {
				ostringstream o;
				o << "the catch-up made no progress at " << from << " (target " << l1 << ")";
				why = o.str();
				return false;
			}
		}
		why = "the catch-up did not reach its target in 1000 slices";
		return false;
	}
}
#endif

int handler_reconstruction::_staged_rebuild(bool snapshot_ok, const string& peer_master_id, uint64_t l0, bool peer_wal_supported) {
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb == NULL) {
		return -1;
	}
	const string& host = this->_node_server_name;
	const int port = this->_node_server_port;
	const string epoch = this->_probe_source_epoch;
	const bool epoch_bound = this->_epoch_supported && !epoch.empty();
	struct blocker {
		static int stop(storage_rocksdb* r, const char* reason, const string& why) {
			r->set_rebuild_blocked(reason);
			r->set_rebuild_parked(true);
			log_err("CRITICAL: rebuild_blocked=%s — %s; the live copy is KEPT and nothing is discarded; the rebuild is PARKED until the operator resumes it (operator action needed)", reason, why.c_str());
			return -1;
		}
	};
	// a parked rebuild does nothing (no transfer, no checks) until resumed
	if (rdb->is_rebuild_parked()) {
		log_debug("staged rebuild parked (rebuild_blocked=%s): waiting for rebuild_resume", rdb->get_rebuild_blocked().c_str());
		return -1;
	}

	// --- may it start? ---------------------------------------------------
	if (peer_master_id.empty() || (!epoch_bound && !peer_wal_supported)) {
		return blocker::stop(rdb, "source_unverifiable",
			"the source gives no lineage or no replication position: a staged copy of it cannot be verified (design §3.2)");
	}
	if (!epoch_bound) {
		// a source older than continuous replication: no epoch-bound catch-up,
		// so a copy is only taken when the position does not move from L0 to
		// after the switch — evidence for that interval only; the write stop
		// itself must be held OUTSIDE until this node is Active (design §3.2)
		log_warning("legacy source (no source epoch): the staged copy is accepted only if the source position stays at %llu until after the switch — the WRITE STOP MUST BE HELD OUTSIDE until this replica is Active", (unsigned long long)l0);
		snapshot_ok = false;	// a checkpoint without an epoch is refused anyway
	}
	{
		// Retained copies are NOT a generation limit (only quarantine is,
		// design §6): they stay until §8 or an approval, and the space they
		// take is already reflected in what the filesystem reports as free —
		// the capacity check below decides (CI 37578618876: a one-retained
		// limit blocked a replica's second rebuild forever).
		const vector<string> retained = rdb->list_retained();
		if (!retained.empty()) {
			log_notice("staged rebuild: %zu retained copy(ies) kept here (deleted under the §8 conditions or by an approval); their space counts in the capacity check", retained.size());
		}
	}
	copy_identity src;
	handler_reconstruction::probe_source_identity(host, port, src);
	{
		uint64_t need = 0;
		string why;
		const capacity_verdict v = decide_rebuild_capacity(rdb->get_rebuild_reserve_bytes(), src.size_known, src.copy_bytes,
			rdb->rebuild_space_available(), need, why);
		if (v != capacity_ok) {
			return blocker::stop(rdb, capacity_verdict_name(v), why);
		}
		log_notice("staged rebuild may start: %s", why.c_str());
	}
	rdb->set_rebuild_blocked("");
	// a staged copy, its catch-up or its switch is running until this returns
	struct in_flight_guard {
		storage_rocksdb* r;
		in_flight_guard(storage_rocksdb* x): r(x) { r->set_rebuild_in_flight(true); }
		~in_flight_guard() { r->set_rebuild_in_flight(false); }
	} in_flight(rdb);
	rdb->peaks_begin(false);		// the measured window of this staged rebuild
	boost::function<bool (string&)> watch = boost::bind(&handler_reconstruction::_space_watch, this, _1);

	// --- copy into staging ------------------------------------------------
	string attempt = storage_rocksdb::new_attempt_id();
	storage_rocksdb* stg = NULL;
	uint64_t start_lsn = l0;
	bool used_snapshot = false;
	struct abandon {
		static int now(storage_rocksdb* r, storage_rocksdb*& s, const string& a, const string& why) {
			if (s != NULL) {
				delete s;
				s = NULL;
			}
			r->remove_staging(a);
			r->note_staged_result(false);
			log_warning("staged rebuild ABANDONED (%s): the staging copy is removed and the live copy is unchanged", why.c_str());
			return -1;
		}
	};
	if (snapshot_ok) {
		string dir;
		if (rdb->make_staging_dir(attempt, dir) == 0) {
			this->_thread->set_op("repl_snapshot");
			shared_connection cs(bounded_connection(host, port));
			bool received = false;
			bool busy = false;
			uint64_t cp_seq = 0;
			string cp_master_id;
			if (cs->open() == 0) {
				op_repl_snapshot* sp = new op_repl_snapshot(cs, this->_storage);
				sp->set_bwlimit(this->_reconstruction_bwlimit);
				sp->set_receive_dir(dir);
				sp->set_space_watch(watch);
				received = sp->run_client() == 0;
				busy = sp->is_busy();
				cp_seq = sp->get_received_seq();
				cp_master_id = sp->get_received_master_id();
				delete sp;
			}
			if (received) {
				stg = rdb->open_staging(attempt, true);
			}
			string why;
			if (stg == NULL) {
				why = received ? "the received checkpoint does not open" : "the snapshot transfer failed";
			} else if (stg->get_staging_found_epoch() != epoch) {
				why = "the checkpoint carries history " + stg->get_staging_found_epoch() + ", not the probed " + epoch;
			} else if (stg->get_master_id() != peer_master_id) {
				why = "the checkpoint carries lineage " + stg->get_master_id() + ", not the probed " + peer_master_id;
			} else if (stg->adopt_history(peer_master_id, epoch, cp_seq) < 0) {
				why = "the checkpoint's history could not be adopted";
			}
			if (!why.empty()) {
				abandon::now(rdb, stg, attempt, busy ? "the source is serving another snapshot (busy): waiting, no dump instead" : why);
				if (busy || rdb->get_rebuild_blocked() == "no_space") {
					return -1;
				}
				log_notice("falling back to a staged full dump", 0);
				attempt = storage_rocksdb::new_attempt_id();
			} else {
				start_lsn = cp_seq;
				used_snapshot = true;
				log_notice("staged snapshot: checkpoint sequence %llu (attempt %s, copy %s)", (unsigned long long)cp_seq,
					attempt.c_str(), stg->get_copy_id().c_str());
			}
		}
	}
	if (stg == NULL) {
		stg = rdb->open_staging(attempt, false);
		if (stg == NULL) {
			return abandon::now(rdb, stg, attempt, "the staging copy could not be created");
		}
		if (stg->adopt_history(peer_master_id, epoch_bound ? epoch : string(""), l0) < 0) {
			return abandon::now(rdb, stg, attempt, "the staging copy could not adopt the source's lineage");
		}
		shared_connection cd(bounded_connection(host, port));
		if (cd->open() < 0) {
			return abandon::now(rdb, stg, attempt, "no connection for the dump");
		}
		op_dump* p = new op_dump(cd, this->_cluster, stg);
		p->set_thread(this->_thread);
		p->set_strict(true);
		p->set_space_watch(watch);
		this->_thread->set_state("execute");
		this->_thread->set_op(p->get_ident());
		log_notice("starting dump operation into staging copy %s (attempt %s; master=%s:%d, partition=%d, partition_size=%d, L0=%llu)",
			stg->get_copy_id().c_str(), attempt.c_str(), host.c_str(), port, this->_partition, this->_partition_size, (unsigned long long)l0);
		const int dr = p->run_client(this->_reconstruction_interval, this->_partition, this->_partition_size, this->_reconstruction_bwlimit);
		const bool complete = dr == 0 && p->is_completed();
		const uint64_t items = p->get_items();
		delete p;
		if (!complete) {
			return abandon::now(rdb, stg, attempt, "the dump did not complete (no END marker, a store failure, the space watch, or shutdown)");
		}
		log_notice("reconstruction via full dump completed into staging (%llu items received)", (unsigned long long)items);
	}

	// --- fixed target L1, same lineage and history -----------------------
	string end_master_id, end_epoch;
	uint64_t l1 = 0;
	if (!probe_position(host, port, this->_storage, end_master_id, l1, end_epoch)) {
		return abandon::now(rdb, stg, attempt, "the source could not be probed after the copy (Unknown)");
	}
	if (end_master_id != peer_master_id || end_epoch != (epoch_bound ? epoch : end_epoch)) {
		return abandon::now(rdb, stg, attempt, "the source's identity changed during the copy (master_id " + peer_master_id + " -> "
			+ end_master_id + ", epoch " + epoch + " -> " + end_epoch + ")");
	}
	if (epoch_bound) {
		string why;
		this->_thread->set_op("repl_sync_wal");
		if (!catch_up_to(host, port, stg, rdb, peer_master_id, epoch, l1, this->_reconstruction_bwlimit, this->_reconstruction_interval, why)) {
			return abandon::now(rdb, stg, attempt, why);
		}
		log_notice("staging copy caught up to the fixed target L1=%llu (from %llu, history %s): cursor %llu",
			(unsigned long long)l1, (unsigned long long)start_lsn, epoch.c_str(), (unsigned long long)stg->get_repl_last_lsn());
	} else if (l1 != l0) {
		return abandon::now(rdb, stg, attempt, "legacy source: the position moved during the copy (L0 " + boost::lexical_cast<string>(l0)
			+ ", L1 " + boost::lexical_cast<string>(l1) + "): writes were not stopped");
	}

	// --- verify, then the protection rule right before the switch --------
	if (!stg->copy_identity_consistent() || stg->get_master_id() != peer_master_id
			|| (epoch_bound && (stg->get_source_epoch() != epoch || stg->get_repl_last_lsn() < l1))) {
		return abandon::now(rdb, stg, attempt, "the staging copy failed its final check (identity, lineage, history or position)");
	}
	log_notice("staging copy %s verified: lineage %s, history %s, position %llu >= L1 %llu; %llu keys (source reported %llu%s; counts are not a criterion)",
		stg->get_copy_id().c_str(), peer_master_id.c_str(), epoch_bound ? epoch.c_str() : "(legacy)", (unsigned long long)stg->get_repl_last_lsn(),
		(unsigned long long)l1, (unsigned long long)stg->count(), (unsigned long long)src.items, src.known ? "" : ", unknown");
	{
		string gwhy;
		if (!copy_gate_allows(this->_copy_gate("switch to the verified staging copy", gwhy))) {
			return abandon::now(rdb, stg, attempt, "copy protection: " + gwhy);
		}
	}
	if (!epoch_bound) {
		string m, e;
		uint64_t now_lsn = 0;
		if (!probe_position(host, port, this->_storage, m, now_lsn, e) || m != peer_master_id || now_lsn != l0) {
			return abandon::now(rdb, stg, attempt, "legacy source: the position is not still L0 right before the switch");
		}
	}
	rdb->peaks_sample(false, true);	// after the catch-up, before the seal
	const string new_id = stg->get_copy_id();
	if (stg->seal() < 0) {
		return abandon::now(rdb, stg, attempt, "the staging copy could not be made durable");
	}
	delete stg;
	stg = NULL;

	// --- switch (the old copy is retained) --------------------------------
	if (rdb->switch_to_staging(attempt, new_id) < 0) {
		if (rdb->get_copy_id() != new_id) {
			return abandon::now(rdb, stg, attempt, "the switch did not complete (the live copy is the old one)");
		}
		rdb->note_staged_result(false);
		this->_copy_dirty = true;
		log_err("the switch to copy %s did not finish cleanly; nothing is activated (the next open resolves the intent)", new_id.c_str());
		return -1;
	}
	rdb->note_staged_result(true);
	// the live copy is now the new one (from this source's history)
	this->_copy_dirty = true;
	if (used_snapshot) {
		rdb->incr_snapshot_bootstrap();
	}
	if (rdb->record_retained(attempt, peer_master_id, epoch_bound ? epoch : string("")) < 0) {
		log_warning("the retained copy %s%s has no record of what replaced it: it is kept until an explicit approval", copy_fs::kRetainedPrefix, attempt.c_str());
	}
	if (epoch_bound && rdb->set_rebuilt_from(peer_master_id, epoch) < 0) {
		log_warning("could not persist the rebuild evidence; this copy carries none", 0);
	}

	// --- after the switch: catch up (epoch bound) / position check (legacy)
	if (epoch_bound) {
		string m, e, why;
		uint64_t now_lsn = 0;
		if (!probe_position(host, port, this->_storage, m, now_lsn, e) || m != peer_master_id || e != epoch) {
			log_warning("after the switch the source could not be confirmed (Unknown or changed): not activated; the next attempt resumes from cursor %llu",
				(unsigned long long)rdb->get_repl_last_lsn());
			return -1;
		}
		if (!catch_up_to(host, port, rdb, rdb, peer_master_id, epoch, now_lsn, this->_reconstruction_bwlimit, this->_reconstruction_interval, why)) {
			log_warning("after the switch the catch-up failed (%s): not activated; the next attempt resumes from cursor %llu", why.c_str(),
				(unsigned long long)rdb->get_repl_last_lsn());
			return -1;
		}
	} else {
		string m, e;
		uint64_t now_lsn = 0;
		if (!probe_position(host, port, this->_storage, m, now_lsn, e) || m != peer_master_id || now_lsn != l0) {
			return blocker::stop(rdb, "legacy_source_writes",
				"legacy source: the position moved between L0 and after the switch — the write stop was not held, so this copy may miss writes; it is NOT activated (the old copy is retained)");
		}
	}
	rdb->peaks_sample(false, true);
	{
		uint64_t dmax = 0, dstart = 0, n = 0;
		int64_t mmax = -1, amin = -1;
		rdb->peaks_get(false, dmax, mmax, amin, dstart, n);
		log_notice("staged rebuild peaks: data dir %llu bytes at most (from %llu: growth %llu), cgroup memory %lld bytes at most, least free %lld bytes, %llu samples (receiver side; reserve sizing, design §9)",
			(unsigned long long)dmax, (unsigned long long)dstart, (unsigned long long)(dmax > dstart ? dmax - dstart : 0),
			(long long)mmax, (long long)amin, (unsigned long long)n);
	}
	log_notice("staged rebuild DONE: live copy %s (lineage %s, history %s, cursor %llu); the old copy is retained as %s%s",
		rdb->get_copy_id().c_str(), peer_master_id.c_str(), epoch_bound ? epoch.c_str() : "(legacy)", (unsigned long long)rdb->get_repl_last_lsn(),
		copy_fs::kRetainedPrefix, attempt.c_str());
	return 0;
#else
	(void)snapshot_ok;
	(void)peer_master_id;
	(void)l0;
	(void)peer_wal_supported;
	return -1;
#endif
}

/**
 *	activate_node with bounded retry (see the activation comment in
 *	_run_once). ~1 minute of attempts covers any realistic index leader
 *	handover; shutdown requests abort immediately. EVERY attempt first
 *	re-validates the copy's source (_check_source): a CONFIRMED master change or
 *	a same-name source with a new history while activation is retrying stops
 *	it — the copy is not activated, and the next reconstruction attempt
 *	starts clean from the current master.
 */
int handler_reconstruction::_activate_with_retry(bool skip_ready_state) {
	int rc = -1;
	for (int i = 0; i < 30; i++) {
		string why;
		const uint64_t map_version = this->_cluster->get_node_map_version();
		const source_check sc = this->_check_source(why);
		if (sc == source_changed) {
			log_warning("activation STOPPED before attempt %d: %s -> the copy is not activated; retrying the reconstruction from the current master with a clean copy", i + 1, why.c_str());
			if (this->_role == cluster::role_slave) this->_cluster->reset_read_source("activation stopped: " + why);
			return -2;
		}
		if (sc == source_copy_unverified) {
			log_warning("activation STOPPED before attempt %d: %s -> taking the copy again", i + 1, why.c_str());
			if (this->_role == cluster::role_slave) this->_cluster->reset_read_source("activation stopped: " + why);
			return -3;
		}
		if (sc == source_unknown) {
			// Unknown is neither valid nor a change: no activation this
			// attempt, the copy is KEPT, and the source is checked again.
			log_warning("activation deferred (attempt %d): %s", i + 1, why.c_str());
			for (int j = 0; j < 2; j++) {
				if (this->_thread->is_shutdown_request()) {
					return -1;
				}
				sleep(1);
			}
			continue;
		}
		// The decision's inputs, for placing it against a master switch: the
		// map version read BEFORE the check (a newer map may arrive during
		// the probe; the next attempt checks against it).
		log_notice("activation source check passed (attempt %d): source %s is the partition's master in the map read at version %llu (now %llu); copy master_id %s, source epoch %s",
			i + 1, this->_cluster->to_node_key(this->_node_server_name, this->_node_server_port).c_str(),
			(unsigned long long)map_version, (unsigned long long)this->_cluster->get_node_map_version(),
			this->_attempt_master_id.c_str(), this->_probe_source_epoch.c_str());
		// R3: bind the copy to the source it was just checked against, BEFORE
		// asking for activation: harmless while the map still says Prepare
		// (a Prepare node never answers locally), and it covers an
		// activation the controller performs itself after this handler gave
		// up. bind_read_source re-checks against the map in force.
#ifdef HAVE_LIBROCKSDB
		storage_rocksdb* idrdb = dynamic_cast<storage_rocksdb*>(this->_storage);
		const bool identity_ok = idrdb == NULL || (idrdb->copy_identity_consistent() && !idrdb->is_quarantined());
#else
		const bool identity_ok = true;
#endif
		if (!identity_ok) {
			log_warning("read source NOT bound: this copy is not a healthy copy (identity records disagree, or it is the empty copy left by a quarantine); reads stay forwarded until a verified rebuild", 0);
		}
		if (this->_role == cluster::role_slave && identity_ok) {
			this->_cluster->bind_read_source(this->_cluster->to_node_key(this->_node_server_name, this->_node_server_port),
				this->_attempt_master_id, this->_epoch_supported ? this->_probe_source_epoch : string(""),
				"the copy passed its source check (activation attempt " + boost::lexical_cast<string>(i + 1) + ")");
		}
		// TEST SEAM (E2E only): while the named file exists, an activation
		// attempt fails as if the index server had refused it.
		const char* hold = getenv("FLARE_TEST_ACTIVATION_HOLD_FILE");
		struct stat st;
		if (hold != NULL && hold[0] != '\0' && stat(hold, &st) == 0) {
			log_warning("node activation failed (attempt %d): held by FLARE_TEST_ACTIVATION_HOLD_FILE (test seam) -> retrying in 2 seconds", i + 1);
		} else {
			rc = this->_cluster->activate_node(skip_ready_state);
			if (rc == 0) {
				const string src_key = this->_cluster->to_node_key(this->_node_server_name, this->_node_server_port);
				log_notice("node activated (attempt %d) on the copy from %s (map version now %llu)",
					i + 1, src_key.c_str(), (unsigned long long)this->_cluster->get_node_map_version());
				return 0;
			}
			log_warning("node activation failed (attempt %d) -> retrying in 2 seconds", i + 1);
		}
		for (int j = 0; j < 2; j++) {
			if (this->_thread->is_shutdown_request()) {
				log_notice("shutdown requested -> abandoning activation retry", 0);
				return -1;
			}
			sleep(1);
		}
	}
	log_err("node activation did not succeed in this round (the copy stays pending; the next round validates it again without copying)", 0);
	return -1;
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
		bool& peer_reachable, bool& peer_snapshot_supported) {
	peer_wal_supported = false;
	peer_snapshot_supported = false;
	peer_master_id.clear();
	peer_latest_lsn = 0;
	peer_reachable = false;
	this->_probe_source_epoch.clear();
	this->_identity_known = false;
	this->_epoch_supported = false;
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
		peer_snapshot_supported = meta->get_peer_snapshot_supported();
		this->_probe_source_epoch = meta->get_peer_source_epoch();
		this->_epoch_supported = meta->get_peer_epoch_token();
		delete meta;
		peer_reachable = (meta_rc == 0);
		this->_identity_known = (meta_rc == 0 && peer_wal_supported && !peer_master_id.empty());
		if (meta_rc != 0 || !peer_wal_supported) {
			log_info("master does not support WAL replication -> full dump", 0);
			return false;
		}
	}

	// The source changed after this handler modified the copy: never resume
	// a partial copy of one history from another source's WAL.
	if (this->_force_clean) {
		log_notice("WAL reconstruction skipped: the source changed after this copy was modified -> clean full rebuild", 0);
		return false;
	}

	// TEST SEAM (E2E only): force every rebuild of an existing copy through
	// the full-dump path, so a test can interrupt a dump over a copy that
	// already carries rebuild evidence.
	{
		const char* no_wal = getenv("FLARE_TEST_DISABLE_WAL_RECONSTRUCTION");
		if (no_wal != NULL && no_wal[0] != '\0' && strcmp(no_wal, "0") != 0) {
			log_warning("WAL reconstruction disabled by FLARE_TEST_DISABLE_WAL_RECONSTRUCTION (test seam) -> full dump", 0);
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

	// R3-D: catch-up is bound to the copy's HISTORY. Its token is the
	// rebuild evidence epoch (a copy taken by full dump), else its own
	// source epoch (a snapshot-restored copy adopts the source's). Unknown is
	// never treated as a match: no catch-up, and the guarded rebuild decides.
	string copy_epoch = rdb->get_rebuilt_from_epoch();
	if (copy_epoch.empty()) {
		copy_epoch = rdb->get_source_epoch();
	}
	if (copy_epoch.empty()) {
		log_notice("WAL reconstruction refused: this copy's history is unknown (no epoch) -> no catch-up; the guarded rebuild decides", 0);
		delete wal_op;
		return false;
	}
	int wal_result = wal_op->run_client_reconstruct(last_lsn, local_master_id, copy_epoch);
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
