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
 *	handler_reconstruction.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_RECONSTRUCTION_H
#define	HANDLER_RECONSTRUCTION_H

#include <string>

#include <boost/lexical_cast.hpp>

#include "connection.h"
#include "thread_handler.h"
#include "cluster.h"
#include "storage.h"
#include "copy_protection.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	reconstruction thread handler class
 */
class handler_reconstruction : public thread_handler {
protected:
	cluster*						_cluster;
	storage*						_storage;
	shared_connection		_connection;
	// The SOURCE: re-selected at the start of every attempt from the current
	// map (a slave's source is its partition's master).
	string							_node_server_name;
	int									_node_server_port;
	// This handler modified the local copy (truncate or a started dump) and
	// has not activated: the copy is partial or belongs to the previous
	// source's history.
	bool								_copy_dirty;
	// The next attempt must start from a clean copy (source changed after
	// the copy was modified): never merge two histories.
	bool								_force_clean;
	// The source's lineage as probed at the start of this attempt (with
	// _probe_source_epoch): what the copy was taken from.
	string							_attempt_master_id;
	// The copy-time identity probe was COMPLETE (answered, RocksDB WAL
	// features, master_id present); only then can the copy be validated.
	bool								_identity_known;
	// The copy-time reply carried a source_epoch token. Absent from a
	// complete reply = an older flared (lineage-only compatibility).
	bool								_epoch_supported;
	// A slave copy is COMPLETE and awaits validation + activation. While the
	// source is Unknown the retries only re-validate; they never return to a
	// transfer (WAL, snapshot, dump).
	bool								_pending_activation;

	int									_partition;
	int									_partition_size;
	cluster::role				_role;
	int									_reconstruction_interval;
	int									_reconstruction_bwlimit;
	// Source epoch the master advertised in the pre-dump features probe.
	string									_probe_source_epoch;
	// The id this handler was given by stats::reconstruction_begin(); every
	// completion notification carries it, so a late notification from an
	// older handler cannot be attributed to a newer reconstruction.
	uint64_t						_reconstruction_id;

public:
	handler_reconstruction(shared_thread t, cluster* cl, storage* st, string node_server_name, int node_server_port, int partition, int partition_size, cluster::role r, int reconstruction_interval, int reconstruction_bwlimit);
	virtual ~handler_reconstruction();

	virtual int run();

protected:
	int _run_once();
	int _activate_with_retry(bool skip_ready_state);
	// R3-D: the protection rule (copy_protection.h) evaluated NOW, right
	// before a destructive step on this slave's copy. Logs the decision.
	// strict: a discard BEFORE the replacement is copied also needs a source
	// that holds keys (the empty-source exceptions do not apply)
	copy_gate _copy_gate(const char* step, string& why, bool strict = false);
	// COPY RETENTION (docs/design-copy-retention.md §3): build the replacement
	// in data_dir/staging-<attempt> (snapshot, else full dump) next to the
	// live copy, bring it to the fixed target L1 by a WAL catch-up bound to
	// the source's history, verify it, switch it in (the old copy is
	// RETAINED), record it and catch up. 0 = the verified copy is live;
	// -1 = stopped or failed with the live copy unchanged, or switched but
	// not yet caught up (the next attempt resumes from its cursor).
	int _staged_rebuild(bool snapshot_ok, const string& peer_master_id, uint64_t l0, bool peer_wal_supported);
	// the space watch while a staging copy grows (false = stop the copy)
	bool _space_watch(string& why);
	// TEST SEAMS: hold while the file named by `env` exists (false =
	// shutdown requested while held)
	bool _test_hold(const char* env, const char* where);
	// a bounded `stats` read of the source: items and identity
	static void probe_source_identity(const string& host, int port, copy_identity& out);
	// Is the copy's source still valid for activation? THREE outcomes:
	//   source_valid    — same node is the partition's master in the current
	//                     map, and a fresh probe shows the same lineage and
	//                     source epoch;
	//   source_changed  — CONFIRMED otherwise: another master in the map, or
	//                     the probe answered with another lineage/epoch (a
	//                     same-name source re-promoted, restored or
	//                     bulk-rewritten) -> the copy is rebuilt clean;
	//   source_unknown  — the probe could not be completed (connect/read
	//                     failure): NOT valid (no activation) and NOT a
	//                     change (the copy is kept; check again).
	//   source_copy_unverified — the copy-time identity was not established
	//                     (incomplete probe): the copy can never be validated
	//                     and is taken again (not a confirmed change).
	enum source_check { source_valid, source_changed, source_unknown, source_copy_unverified };
	// Validate and activate a completed copy: 0 = activated, -1 = still
	// pending (Unknown, or activation refused), -2 = confirmed source change
	// (copy dropped, clean rebuild), -3 = copy unverifiable (taken again).
	int _activate_pending();
	source_check _check_source(string& why);

protected:
	// Try to catch up from the master via incremental WAL sync instead of
	// a full dump. Returns true only when the delta was fully applied (so
	// the caller can skip the dump); false — safely — otherwise, after
	// which the caller performs the non-destructive full dump. Always
	// probes the master's features first and reports them via the out-
	// params (even when declining WAL), so the caller can seed the cursor
	// after a full-dump fallback. peer_latest_lsn is the master's LSN as of
	// BEFORE the dump. peer_reachable reports whether the feature probe got
	// ANY response (source alive) — the caller uses it to decide whether a
	// truncate-before-dump is safe (never truncate against a dead source).
	bool _try_wal_reconstruction(shared_connection c, bool& peer_wal_supported, string& peer_master_id, uint64_t& peer_latest_lsn, bool& peer_reachable, bool& peer_snapshot_supported);

	// After a full-dump reconstruction (and master_id adoption), durably
	// seed repl_last_lsn from the master's pre-dump latest_lsn so the next
	// reconstruction can use incremental WAL sync. No-op unless rocksdb,
	// the peer supports WAL, peer_latest_lsn > 0, and a master_id is set.
	void _seed_repl_lsn_after_dump(shared_connection c, bool peer_wal_supported, uint64_t peer_latest_lsn);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_RECONSTRUCTION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
