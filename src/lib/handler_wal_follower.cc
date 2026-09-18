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
 *	handler_wal_follower.cc
 *
 *	implementation of gree::flare::handler_wal_follower
 */
#include "handler_wal_follower.h"

#include "app.h"
#include "connection_tcp.h"
#include "op_repl_sync_wal.h"
#include "stats.h"

#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

namespace gree {
namespace flare {

// {{{ ctor/dtor
handler_wal_follower::handler_wal_follower(shared_thread t, cluster* cl, storage* st,
		string source_name, int source_port,
		uint64_t max_batches, uint64_t max_response_bytes, int poll_interval_usec):
		thread_handler(t),
		_cluster(cl),
		_storage(st),
		_source_name(source_name),
		_source_port(source_port),
		_max_batches(max_batches),
		_max_response_bytes(max_response_bytes),
		_poll_interval_usec(poll_interval_usec) {
}

handler_wal_follower::~handler_wal_follower() {
}
// }}}

// {{{ public methods
/**
 *	The decision table, kept pure so the rule that matters most here — a lost
 *	connection is NOT a repair trigger — can be tested without a socket.
 */
handler_wal_follower::attempt_outcome handler_wal_follower::classify(int client_result, bool transport_ok) {
	if (!transport_ok) {
		// Could not reach the source, or the stream broke mid-slice. The
		// position and the data are intact, so this is a reconnect, never a
		// rebuild (design §5.4).
		return attempt_disconnected;
	}
	switch (client_result) {
		case op_repl_sync_wal::client_success:
			return attempt_progress;
		case op_repl_sync_wal::client_lsn_purged:
		case op_repl_sync_wal::client_epoch_mismatch:
		case op_repl_sync_wal::client_master_id_mismatch:
		case op_repl_sync_wal::client_lsn_ahead:
			// Our position can never be satisfied from this source again:
			// the history it needs is gone, or the source is serving another
			// one. Only these hand the node to the rebuild path.
			return attempt_needs_rebuild;
		case op_repl_sync_wal::client_no_epoch:
		case op_repl_sync_wal::client_not_supported:
			// The source cannot identify its history (or does not speak this
			// op). Not our data's fault: keep the copy, stop asking, and let
			// the controller decide.
			return attempt_error;
		default:
			return attempt_error;
	}
}

const char* handler_wal_follower::reason_for(int client_result) {
	switch (client_result) {
		case op_repl_sync_wal::client_success:            return "";
		case op_repl_sync_wal::client_lsn_purged:         return "lsn_purged";
		case op_repl_sync_wal::client_epoch_mismatch:     return "epoch_mismatch";
		case op_repl_sync_wal::client_master_id_mismatch: return "master_id_mismatch";
		case op_repl_sync_wal::client_lsn_ahead:          return "lsn_ahead";
		case op_repl_sync_wal::client_no_epoch:           return "source_has_no_epoch";
		case op_repl_sync_wal::client_not_supported:      return "not_supported";
		case op_repl_sync_wal::client_apply_error:        return "apply_error";
		case op_repl_sync_wal::client_protocol_error:     return "protocol_error";
		default:                                          return "server_error";
	}
}

int handler_wal_follower::run() {
#ifdef HAVE_LIBROCKSDB
	this->_thread->set_peer(this->_source_name, this->_source_port);
	this->_thread->set_state("follow");

	char source[BUFSIZ];
	snprintf(source, sizeof(source), "%s:%d", this->_source_name.c_str(), this->_source_port);

	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb == NULL) {
		log_warning("continuous replication requested on a backend without one -> not following", 0);
		if (stats_object != NULL) stats_object->follow_set_state(stats::follow_error, "backend_without_wal");
		return -1;
	}
	if (stats_object != NULL) stats_object->follow_set_source(string(source), rdb->get_source_epoch());
	if (stats_object != NULL) stats_object->follow_set_state(stats::follow_initial_sync, "");

	int backoff = 1;
	while (!this->_thread->is_shutdown_request()) {
		bool more = false;
		const int r = this->_follow_once(more);

		if (r == attempt_needs_rebuild) {
			// Terminal for this handler: the node must be rebuilt, and that
			// decision belongs to the controller, not to this thread.
			return -1;
		}
		if (r == attempt_progress && more) {
			backoff = 1;
			continue;					// more is waiting: ask again at once
		}
		if (r == attempt_progress || r == attempt_idle) {
			backoff = 1;
			// Nothing waiting. Poll again shortly — this is what makes a
			// replica catch up after a blip WITHOUT needing a new write to
			// arrive from anywhere.
			if (this->_poll_interval_usec > 0) {
				usleep(this->_poll_interval_usec);
			}
			continue;
		}

		// Disconnected or failed: keep the data, keep the position, come
		// back. Bounded backoff so a dead source costs nothing.
		for (int i = 0; i < backoff && !this->_thread->is_shutdown_request(); i++) {
			sleep(1);
		}
		backoff = backoff < 30 ? backoff * 2 : 30;
	}

	if (stats_object != NULL) stats_object->follow_set_state(stats::follow_idle, "shutdown");
	return 0;
#else
	log_warning("continuous replication requested but RocksDB is not compiled in", 0);
	return -1;
#endif
}
// }}}

// {{{ private methods
int handler_wal_follower::_follow_once(bool& more) {
#ifdef HAVE_LIBROCKSDB
	more = false;
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb == NULL) {
		return attempt_error;
	}

	const uint64_t cursor = rdb->get_repl_last_lsn();
	const string master_id = rdb->get_master_id();
	const string epoch = rdb->get_source_epoch();
	const string incarnation = rdb->get_incarnation();
	if (cursor == 0 || epoch.empty() || incarnation.empty()) {
		// Nothing to be incremental from, or no identity to bind it to. The
		// initial copy is the snapshot path's job (design §4, condition 5).
		if (stats_object != NULL) stats_object->follow_set_state(stats::follow_needs_rebuild,
			cursor == 0 ? "no_position" : "generations_unavailable");
		return attempt_needs_rebuild;
	}

	shared_connection c(new connection_tcp(this->_source_name, this->_source_port));
	if (c->open() < 0) {
		if (stats_object != NULL) stats_object->follow_set_state(stats::follow_disconnected, "peer_unreachable");
		return attempt_disconnected;
	}

	op_repl_sync_wal* op = new op_repl_sync_wal(c, this->_storage);
	op->set_max_batch_bytes(rdb->get_wal_max_batch_bytes());
	op->set_wal_sync_bwlimit(rdb->get_wal_sync_bwlimit());
	op->set_wal_sync_interval(rdb->get_wal_sync_interval());
	const int rc = op->run_client_follow(cursor, master_id, epoch, incarnation,
		this->_max_batches, this->_max_response_bytes);
	const int client_result = static_cast<int>(op->get_client_result());
	const bool transport_ok = (rc == 0) || (client_result != op_repl_sync_wal::client_protocol_error);
	const uint64_t applied = op->get_applied();
	const uint64_t server_lsn = op->get_server_latest_lsn();
	more = op->get_more_available();
	delete op;

	if (server_lsn > 0) {
		// The source's position, recorded WITH the time it was observed.
		if (stats_object != NULL) stats_object->follow_note_source_position(server_lsn);
	}

	const attempt_outcome outcome = classify(client_result, transport_ok);
	switch (outcome) {
		case attempt_progress:
			if (stats_object != NULL) stats_object->follow_note_progress(rdb->get_repl_last_lsn());
			if (stats_object != NULL) stats_object->follow_set_state(stats::follow_following, "");
			return applied > 0 ? attempt_progress : attempt_idle;
		case attempt_needs_rebuild:
			if (stats_object != NULL) stats_object->follow_set_state(stats::follow_needs_rebuild, reason_for(client_result));
			return attempt_needs_rebuild;
		case attempt_disconnected:
			if (stats_object != NULL) stats_object->follow_set_state(stats::follow_disconnected, reason_for(client_result));
			return attempt_disconnected;
		default:
			if (stats_object != NULL) stats_object->follow_set_state(stats::follow_error, reason_for(client_result));
			return attempt_error;
	}
#else
	(void)more;
	return attempt_error;
#endif
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
