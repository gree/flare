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
 *	op_stats.cc
 *
 *	implementation of gree::flare::op_stats
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "op_stats.h"
#include "binary_request_header.h"
#include "binary_response_header.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif
#include <malloc.h>
#include <sstream>

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_stats
 */
op_stats::op_stats(shared_connection c):
		op(c, "stats", binary_header::opcode_stat),
		_stats_type(stats_type_default) {
}

/**
 *	dtor for op_stats
 */
op_stats::~op_stats() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
op_stats::stats_type op_stats::_parse_stats_type(const char* body) const {
	stats_type type = stats_type_default;
	if (body) {
		char word[BUFSIZ];
		int n = util::next_word(body, word, sizeof(word));
		if (word[0] == '\0') {
			type = stats_type_default;
		} else if (strcmp(word, "items") == 0) {
			type = stats_type_items;
		} else if (strcmp(word, "slabs") == 0) {
			type = stats_type_slabs;
		} else if (strcmp(word, "sizes") == 0) {
			type = stats_type_sizes;
		} else if (strcmp(word, "threads") == 0) {
			char word2[BUFSIZ];
			util::next_word(body+n, word2, sizeof(word2));
			if (word2[0] == '\0') {
				type = stats_type_threads;
			} else if (strcmp(word2, "request") == 0) {
				type = stats_type_threads_request;
			} else if (strcmp(word2, "slave") == 0) {
				type = stats_type_threads_slave;
			} else if (strcmp(word2, "queue") == 0) {
				type = stats_type_threads_queue;
			} else {
				type = stats_type_error;
			}
		} else if (strcmp(word, "nodes") == 0) {
			type = stats_type_nodes;
		} else {
			type = stats_type_error;
		}
	}
	return type;
}

int op_stats::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	this->_stats_type = this->_parse_stats_type(p);
	log_debug("parameter=%s -> stats_type=%d", p, this->_stats_type);
	delete[] p;

	if (this->_stats_type == stats_type_error) {
		return -1;
	}

	return 0;
}

int op_stats::_parse_binary_request(const binary_request_header& header, const char* body) {
	this->_stats_type = this->_parse_stats_type(std::string(body, header.get_total_body_length()).c_str());
	return this->_stats_type != stats_type_error ? 0 : -1;
}

int op_stats::_run_server() {
	return 0;
}

int op_stats::_send_stats(thread_pool* req_tp, thread_pool* other_tp, storage* st, cluster* cl) {
	rusage usage = stats_object->get_rusage();
	char usage_user[BUFSIZ];
	char usage_system[BUFSIZ];
	snprintf(usage_user, sizeof(usage_user), "%ld.%06d", usage.ru_utime.tv_sec, static_cast<int>(usage.ru_utime.tv_usec));
	snprintf(usage_system, sizeof(usage_user), "%ld.%06d", usage.ru_stime.tv_sec, static_cast<int>(usage.ru_stime.tv_usec));

	_send_stat("pid"									, stats_object->get_pid());
	_send_stat("uptime" 							, stats_object->get_uptime());
	// Queued proxy requests (forwards to replicas, proxied reads). Only
	// `stats threads queue` carried it before, so plain `stats` readers saw
	// nothing while millions of forwards were queued (2026-10-02).
	_send_stat("total_thread_queue"					, stats_object->get_total_thread_queue());
#if defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 33))
	{
		// Heap accounting (2026-10-02): in-use bytes grow on a leak, free
		// bytes held by the allocator grow on fragmentation. Both are
		// needed to tell them apart when RSS rises with the data.
		struct mallinfo2 mi = ::mallinfo2();
		_send_stat("malloc_in_use_bytes"			, static_cast<uint64_t>(mi.uordblks + mi.hblkhd));
		_send_stat("malloc_free_bytes"				, static_cast<uint64_t>(mi.fordblks));
		_send_stat("malloc_arena_bytes"				, static_cast<uint64_t>(mi.arena));
	}
#endif
	_send_stat("time" 								, stats_object->get_timestamp());
	_send_stat("version"							, stats_object->get_version());
	_send_stat("pointer_size" 				, stats_object->get_pointer_size());
	_send_stat("rusage_user"					, usage_user);
	_send_stat("rusage_system"				, usage_system);
	_send_stat("curr_items" 					, stats_object->get_curr_items(st));
	_send_stat("total_items"					, stats_object->get_total_items());
	_send_stat("bytes"								, stats_object->get_bytes(st));
	_send_stat("curr_connections" 		, stats_object->get_curr_connections(req_tp, other_tp));
	_send_stat("total_connections"		, stats_object->get_total_connections());
	_send_stat("connection_structures", stats_object->get_connection_structures());
	_send_stat("cmd_get"							, stats_object->get_cmd_get());
	_send_stat("cmd_set"							, stats_object->get_cmd_set());
	_send_stat("get_hits" 						, stats_object->get_get_hits());
	_send_stat("get_misses" 					, stats_object->get_get_misses());
	_send_stat("delete_hits"					, stats_object->get_delete_hits());
	_send_stat("proxy_write_dropped"	, stats_object->get_proxy_write_dropped());
	// Per-destination breakdown, so a controller can resync exactly the
	// replica that fell behind. Keys carry the destination in brackets and
	// are therefore skipped by the Prometheus formatter (which only maps
	// known names and the rocksdb_ prefix) — this is for the controller and
	// for a human reading `stats`, not for a time series per replica.
	{
		map<string, uint64_t> dropped_by_dest = stats_object->get_proxy_write_dropped_by_dest();
		for (map<string, uint64_t>::const_iterator it = dropped_by_dest.begin();
				it != dropped_by_dest.end(); it++) {
			char key[BUFSIZ];
			snprintf(key, sizeof(key), "proxy_write_dropped[%s]", it->first.c_str());
			_send_stat(key, it->second);
		}
	}
	_send_stat("delete_misses"				, stats_object->get_delete_misses());
	// Reconstruction lifecycle (see stats.h): a controller that requested a
	// resync reads these back to tell "started and finished" from "never
	// reached this node" — the map may have been ignored or carried only a
	// state change, which dispatches nothing.
	_send_stat("reconstruction_started"		, stats_object->get_reconstruction_started());
	_send_stat("reconstruction_completed"	, stats_object->get_reconstruction_completed());
	_send_stat("reconstruction_failed"		, stats_object->get_reconstruction_failed());
	// The completion RECORD (see stats.h): process identity, the latest
	// reconstruction's id and state, and the id/source of the last success.
	{
		// One snapshot under one lock, so the five lines describe the same
		// instant (a reader must never see a new current_id with an old state).
		stats::reconstruction_record rr = stats_object->get_reconstruction_record();
		_send_stat("reconstruction_boot_id"				, rr.boot_id);
		_send_stat("reconstruction_current_id"			, rr.current_id);
		_send_stat("reconstruction_current_state"		, rr.current_state);
		_send_stat("reconstruction_last_success_id"		, rr.last_success_id);
		_send_stat("reconstruction_last_success_source"	, rr.last_success_source);
	}
	{
		// Continuous replication, follower side (SAF-10b). ONE snapshot: a
		// position without the time it was observed, or a state without a
		// reason, cannot be acted on (design §5.1).
		stats::follow_record fr = stats_object->get_follow_record();
		_send_stat("repl_follow_enabled"                , fr.enabled ? 1 : 0);
		_send_stat("repl_follow_source"                 , fr.source);
		_send_stat("repl_follow_source_epoch"           , fr.source_epoch);
		_send_stat("repl_follow_state"                  , fr.state);
		_send_stat("repl_follow_last_reason"            , fr.last_reason);
		_send_stat("repl_applied_lsn"                   , fr.applied_lsn);
		_send_stat("repl_source_lsn"                    , fr.source_lsn);
		_send_stat("repl_source_lsn_observed_at"        , static_cast<uint64_t>(fr.source_lsn_observed_at));
		_send_stat("repl_last_progress_at"              , static_cast<uint64_t>(fr.last_progress_at));
	}
	_send_stat("incr_hits"						, stats_object->get_incr_hits());
	_send_stat("incr_misses"					, stats_object->get_incr_misses());
	_send_stat("decr_hits"						, stats_object->get_decr_hits());
	_send_stat("decr_misses"					, stats_object->get_decr_misses());
	_send_stat("cas_hits" 						, stats_object->get_cas_hits());
	_send_stat("cas_misses" 					, stats_object->get_cas_misses());
	_send_stat("cas_badval" 					, stats_object->get_cas_badval());
	_send_stat("touch_hits" 					, stats_object->get_touch_hits());
	_send_stat("touch_misses" 				, stats_object->get_touch_misses());
	_send_stat("evictions"						, stats_object->get_evictions());
	_send_stat("bytes_read" 					, stats_object->get_bytes_read());
	_send_stat("bytes_written"				, stats_object->get_bytes_written());
	_send_stat("limit_maxbytes" 			, stats_object->get_limit_maxbytes());
	_send_stat("threads"							, stats_object->get_threads(req_tp, other_tp));
	_send_stat("pool_threads" 				, stats_object->get_pool_threads(req_tp, other_tp));
	_send_stat("node_map_version"		, cl->get_node_map_version());
	// decision 2026-10-08: the map made this node a master over a copy it
	// refuses to serve (0 = not refused)
	_send_stat("promotion_refused"		, cl->is_promotion_refused() ? 1 : 0);
	{
		// R3: the source this node's copy is eligible for. eligible=0 means
		// local reads are withdrawn and the node must not be promoted until
		// it is re-validated; needs_rebuild asks the controller for a rebuild.
		const source_binding rs = cl->get_read_source();
		_send_stat("repl_read_source_eligible"       , rs.is_eligible() ? 1 : 0);
		_send_stat("repl_read_source_state"          , string(source_binding::state_name(rs.st)));
		_send_stat("repl_read_source"                , rs.source);
		_send_stat("repl_read_source_epoch"          , rs.source_epoch);
		_send_stat("repl_read_source_reason"         , rs.reason);
	}

	// Data-dir filesystem usage (statvfs). On tmpfs clusters this is the RAM
	// the dataset occupies — the quantity that drives the pod's memory limit —
	// which container-level memory metrics (working_set) do not show.
	if (st) {
		_send_stat("data_dir_used_bytes"    , st->get_data_dir_used_bytes());
		_send_stat("data_dir_capacity_bytes", st->get_data_dir_capacity_bytes());
	}

#ifdef HAVE_LIBROCKSDB
	// RocksDB WAL-replication observability. Only emitted when the
	// storage backend is actually RocksDB so non-RocksDB deployments
	// see no change in `stats` output.
	if (st && st->get_type() == storage::type_rocksdb) {
		storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(st);
		if (rdb) {
			_send_stat("rocksdb_master_id"                  , rdb->get_master_id());
			// Generations (SAF-10, design §3.1): the source epoch identifies
			// the history a follower reads; the incarnation identifies this
			// node's own copy. Neither moves on a plain process restart.
			// Empty means UNAVAILABLE: the node could not establish or persist
			// its identities and refuses to serve or accept replication.
			_send_stat("rocksdb_source_epoch"               , rdb->get_source_epoch());
			_send_stat("rocksdb_copy_id"                    , rdb->get_copy_id());
			_send_stat("rocksdb_copy_identity_consistent"   , rdb->copy_identity_consistent() ? 1 : 0);
			// design §6: the live copy is the empty copy left by a quarantine
			_send_stat("rocksdb_quarantined"                , rdb->is_quarantined() ? 1 : 0);
			// decision 2026-10-08: changed part-way by a merging dump (durable)
			_send_stat("rocksdb_copy_partial"               , rdb->is_copy_partial() ? 1 : 0);
			// restore provenance: the partition / routing layout this copy's
			// data belongs to ("-" = not bound yet) and whether it is a
			// restored copy not yet accepted as that partition's master
			{
				const string pb = rdb->get_partition_binding();
				_send_stat("rocksdb_partition_binding"      , pb.empty() ? string("-") : pb);
			}
			_send_stat("rocksdb_restored_unverified"        , rdb->is_restored_unverified() ? 1 : 0);
			// copy retention (design §3, §8, §9): the live copy's size (what a
			// replica staging a copy of THIS node needs), the reserve, why the
			// last staged rebuild stopped ("" = not blocked), retained copies
			_send_stat("rocksdb_copy_bytes"                 , rdb->local_copy_bytes());
			_send_stat("rocksdb_rebuild_reserve_bytes"      , static_cast<long long>(rdb->get_rebuild_reserve_bytes()));
			_send_stat("rebuild_blocked"                    , rdb->get_rebuild_blocked());
			// design §10: parked = blocked and waiting for rebuild_resume (no
			// automatic retry); in_flight = a staged copy / catch-up / switch
			// running now; serving = a snapshot is being served from here
			_send_stat("rebuild_parked"                     , rdb->is_rebuild_parked() ? 1 : 0);
			{
				// measured peaks (reserve sizing): receiver = the last staged
				// rebuild, source = the last serve (snapshot or dump)
				const char* side[] = { "rebuild", "serve" };
				for (int k = 0; k < 2; k++) {
					uint64_t dmax = 0, dstart = 0, n = 0;
					int64_t mmax = -1, amin = -1;
					rdb->peaks_get(k == 1, dmax, mmax, amin, dstart, n);
					const string pre = string("rocksdb_") + side[k] + "_peak_";
					_send_stat((pre + "data_dir_bytes").c_str(), dmax);
					_send_stat((pre + "data_dir_start_bytes").c_str(), dstart);
					_send_stat((pre + "memory_bytes").c_str(), static_cast<long long>(mmax));
					_send_stat((pre + "min_available_bytes").c_str(), static_cast<long long>(amin));
					_send_stat((pre + "samples").c_str(), n);
				}
			}
			_send_stat("rebuild_in_flight"                  , rdb->is_rebuild_in_flight() ? 1 : 0);
			_send_stat("rocksdb_switch_unresolved"          , rdb->is_switch_unresolved() ? 1 : 0);
			{
				// receipts of completed bulks: "pred>succ@epoch;..." (one line)
				string chain = rdb->get_bulk_chain();
				string flat;
				istringstream in(chain);
				string l;
				while (getline(in, l)) {
					istringstream f(l);
					string pr, su, ep;
					if (f >> pr >> su >> ep) {
						flat += (flat.empty() ? "" : ";") + pr + ">" + su + "@" + ep;
					}
				}
				_send_stat("rocksdb_bulk_chain"                 , flat.empty() ? string("-") : flat);
			}
			_send_stat("rocksdb_snapshot_serving"           , rdb->is_snapshot_serving() ? 1 : 0);
			_send_stat("rocksdb_retained_copies"            , static_cast<uint64_t>(rdb->list_retained().size()));
			// monitoring (decision 2026-10-07, item 2): what the kept copies take
			_send_stat("rocksdb_retained_bytes"             , rdb->bytes_with_prefix("retained-"));
			_send_stat("rocksdb_quarantine_bytes"           , rdb->bytes_with_prefix("quarantine-"));
			_send_stat("rocksdb_staging_bytes"              , rdb->bytes_with_prefix("staging-"));
			_send_stat("rocksdb_staged_switched"            , rdb->get_staged_switched());
			_send_stat("rocksdb_staged_abandoned"           , rdb->get_staged_abandoned());
			_send_stat("rocksdb_source_epoch_reason"        , rdb->get_source_epoch_reason());
			// Rebuild evidence ("" = none): the source a clean full dump came from.
			_send_stat("rocksdb_rebuilt_from_master_id"     , rdb->get_rebuilt_from_master_id());
			_send_stat("rocksdb_rebuilt_from_epoch"         , rdb->get_rebuilt_from_epoch());
			_send_stat("rocksdb_incarnation"                , rdb->get_incarnation());
			_send_stat("rocksdb_generations_broken"         , rdb->generations_broken() ? 1 : 0);
			// Common apply rule (SAF-10b): what each delivery path did.
			// repl_wal_skipped moving while repl_forward_applied moves is the
			// healthy signal of coexistence — the WAL re-delivering changes
			// that forwarding already applied.
			_send_stat("repl_forward_applied"               , rdb->get_repl_forward_applied());
			_send_stat("repl_forward_skipped"               , rdb->get_repl_forward_skipped());
			_send_stat("repl_wal_applied"                   , rdb->get_repl_wal_applied());
			_send_stat("repl_wal_skipped"                   , rdb->get_repl_wal_skipped());
			_send_stat("repl_decode_refused"                , rdb->get_repl_decode_refused());
			// T17: apply-lock timing (microseconds; maxima since start)
			_send_stat("repl_apply_lock_count"              , rdb->get_repl_apply_lock_count());
			_send_stat("repl_apply_lock_hold_us_total"      , rdb->get_repl_apply_lock_hold_us());
			_send_stat("repl_apply_lock_hold_us_max"        , rdb->get_repl_apply_lock_hold_us_max());
			_send_stat("repl_apply_lock_wait_us_max"        , rdb->get_repl_apply_lock_wait_us_max());
			_send_stat("repl_forward_lock_wait_us_max"      , rdb->get_repl_forward_lock_wait_us_max());
			_send_stat("repl_tombstones_dropped"            , rdb->get_repl_tombstones_dropped());
			_send_stat("repl_tombstones"                    , rdb->get_repl_tombstones());
			_send_stat("rocksdb_repl_last_lsn"              , rdb->get_repl_last_lsn());
			_send_stat("rocksdb_latest_sequence_number"     , rdb->get_latest_sequence_number());
			_send_stat("rocksdb_wal_sync_success"           , rdb->get_wal_sync_success());
			_send_stat("rocksdb_wal_sync_lsn_purged"        , rdb->get_wal_sync_lsn_purged());
			_send_stat("rocksdb_wal_sync_lsn_ahead"         , rdb->get_wal_sync_lsn_ahead());
			_send_stat("rocksdb_wal_sync_master_id_mismatch", rdb->get_wal_sync_master_id_mismatch());
			_send_stat("rocksdb_wal_sync_apply_failure"     , rdb->get_wal_sync_apply_failure());
			_send_stat("rocksdb_wal_sync_other_error"       , rdb->get_wal_sync_other_error());
			_send_stat("rocksdb_wal_sync_crc_mismatch"      , rdb->get_wal_sync_crc_mismatch());
			_send_stat("rocksdb_wal_fallback_to_dump"       , rdb->get_wal_fallback_to_dump());
			_send_stat("rocksdb_expire_reaped"              , rdb->get_expire_reaped());
			_send_stat("rocksdb_expire_filtered"            , rdb->get_expire_filtered());
			_send_stat("rocksdb_snapshot_bootstrap"         , rdb->get_snapshot_bootstrap());
			_send_stat("rocksdb_corruption_detected"        , rdb->get_corruption_detected());
			_send_stat("rocksdb_hard_reset"                 , rdb->get_hard_reset());
			_send_stat("rocksdb_rebuild_stale_discarded"    , rdb->get_rebuild_stale_discarded());
			_send_stat("rocksdb_corrupted"                  , rdb->is_corrupted() ? 1 : 0);
			_send_stat("rocksdb_resync_failure_count"       , rdb->get_resync_failure_count());
			_send_stat("rocksdb_resync_failure_threshold"   , rdb->get_resync_failure_threshold());
			_send_stat("rocksdb_wal_max_batch_bytes"        , rdb->get_wal_max_batch_bytes());
			_send_stat("rocksdb_wal_sync_bwlimit"           , rdb->get_wal_sync_bwlimit());
			_send_stat("rocksdb_snapshot_bwlimit"           , rdb->get_snapshot_bwlimit());
			_send_stat("rocksdb_wal_sync_interval"          , rdb->get_wal_sync_interval());
			_send_stat("rocksdb_backup_success"             , rdb->get_backup_success());
			_send_stat("rocksdb_backup_failure"             , rdb->get_backup_failure());
			_send_stat("rocksdb_last_backup_epoch"          , static_cast<uint64_t>(rdb->get_last_backup_epoch()));
		}
	}
#endif

	return 0;
}

int op_stats::_send_stats_items() {
	return 0;
}

int op_stats::_send_stats_slabs() {
	return 0;
}

int op_stats::_send_stats_sizes() {
	return 0;
}

int op_stats::_send_stats(const thread::thread_info& info) {
	char key[BUFSIZ];
	char value[BUFSIZ];
	snprintf(key, sizeof(key), "%u:type", info.id);
	_send_stat(key, info.type);
	snprintf(key, sizeof(key), "%u:peer", info.id);
	snprintf(value, sizeof(value), "%s:%d", info.peer_name.c_str(), info.peer_port);
	_send_stat(key, value);
	snprintf(key, sizeof(key), "%u:op", info.id);
	_send_stat(key, info.op);
	snprintf(key, sizeof(key), "%u:uptime", info.id);
	_send_stat(key, stats_object->get_timestamp() - info.timestamp);
	snprintf(key, sizeof(key), "%u:state", info.id);
	_send_stat(key, info.state);
	snprintf(key, sizeof(key), "%u:info", info.id);
	_send_stat(key, info.info);
	snprintf(key, sizeof(key), "%u:queue", info.id);
	_send_stat(key, info.queue_size);
	snprintf(key, sizeof(key), "%u:behind", info.id);
	_send_stat(key, info.queue_behind);
	return 0;
}

int op_stats::_send_stats_threads(thread_pool* req_tp, thread_pool* other_tp) {
	{
		vector<thread::thread_info> list = req_tp->get_thread_info();
		for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
			_send_stats(*it);
		}
	}
	{
		vector<thread::thread_info> list = other_tp->get_thread_info();
		for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
			_send_stats(*it);
		}
	}
	return 0;
}

int op_stats::_send_stats_threads(thread_pool* req_tp, thread_pool* other_tp, int type) {
	{
		vector<thread::thread_info> list = req_tp->get_thread_info(type);
		for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
			_send_stats(*it);
		}
	}
	{
		vector<thread::thread_info> list = other_tp->get_thread_info(type);
		for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
			_send_stats(*it);
		}
	}
	return 0;
}

int op_stats::_send_stats_nodes(cluster* cl) {
	char key[BUFSIZ];
	vector<cluster::node> v = cl->get_node();
	for (vector<cluster::node>::iterator it = v.begin(); it != v.end(); it++) {
		string node_key = cl->to_node_key(it->node_server_name, it->node_server_port);
		snprintf(key, sizeof(key), "%s:role", node_key.c_str());
		_send_stat(key, cluster::role_cast(it->node_role));
		snprintf(key, sizeof(key), "%s:state", node_key.c_str());
		_send_stat(key, cluster::state_cast(it->node_state));
		snprintf(key, sizeof(key), "%s:partition", node_key.c_str());
		_send_stat(key, it->node_partition);
		snprintf(key, sizeof(key), "%s:balance", node_key.c_str());
		_send_stat(key, it->node_balance);
		snprintf(key, sizeof(key), "%s:thread_type", node_key.c_str());
		_send_stat(key, it->node_thread_type);
	}

	return 0;
}

int op_stats::_send_stats_threads_queue() {
	_send_stat("total_thread_queue", stats_object->get_total_thread_queue());

	return 0;
}

int op_stats::_send_text_result(result r, const char* message) {
	int result = 0;
	if (r == result_end) {
		_text_stream << "END" << line_delimiter;
		result = this->_connection->write(_text_stream.str().c_str(), _text_stream.str().size());
	}	else {
		result = op::_send_text_result(r, message);
	}
	_text_stream.str(std::string());
	return result;
}

int op_stats::_send_binary_result(result r, const char* message) {
	int result = 0;
	if (r == result_end) {
		result = op::_send_binary_response(binary_response_header(this->_opcode), NULL);
	} else {
		result = op::_send_binary_result(r, message);
	}
	_text_stream.str(std::string());
	return result;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
