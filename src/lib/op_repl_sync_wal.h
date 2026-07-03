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
 *	op_repl_sync_wal.h
 *
 *	WAL-based incremental replication for RocksDB (push protocol)
 *
 *	The op runs between a replication SOURCE (the node that has the
 *	data; protocol client) and a DESTINATION (the node that receives
 *	it; protocol server). Two exchanges are defined:
 *
 *	  repl_sync_wal begin <master_id>
 *	    dest replies "LSN <last_lsn>" (its recorded position in the
 *	    source's WAL lineage) or a single-line SERVER_ERROR. The source
 *	    then streams "LSN <seq>\r\nBATCH <size>\r\n<raw bytes>\r\n"
 *	    records and terminates with "END" (or "ABORT <reason>"); the
 *	    dest applies each batch and finally replies "OK <last_lsn>" or
 *	    "SERVER_ERROR <reason>". Both sides stay line-synchronized on
 *	    every non-transport failure path so the caller can safely fall
 *	    back to a full dump on the same connection.
 *
 *	  repl_sync_wal seed <master_id> <lsn>
 *	    sent by the source after a successful full dump: the dest
 *	    adopts the source's lineage token and records <lsn> as its
 *	    replication position so that future syncs can be incremental.
 *
 *	$Id$
 */
#ifndef	OP_REPL_SYNC_WAL_H
#define	OP_REPL_SYNC_WAL_H

#include "op.h"
#include "storage.h"
#include "bwlimitter.h"

#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

using namespace std;

namespace gree {
namespace flare {

class cluster;

/**
 *	opcode class (repl_sync_wal)
 */
class op_repl_sync_wal : public op {
public:
	// Reason a client-side run ended. Used by the caller to decide
	// whether to fall back to a full dump and whether the connection is
	// still usable (see connection_dirty()).
	enum client_result {
		client_success          = 0,
		client_not_supported    = 1,  // server doesn't speak this op
		client_lsn_purged       = 2,  // dest too far behind our WAL
		client_lsn_ahead        = 3,  // dest position newer than our WAL
		client_master_id_mismatch = 4,// different lineage
		client_server_error     = 5,  // any other failure
		client_apply_error      = 6,  // dest failed to apply a batch
		client_protocol_error   = 7,  // unparseable response / transport error
	};

	// Absolute ceiling for a single replicated WriteBatch. Guards the
	// receiving side against absurd BATCH declarations regardless of the
	// configurable rocksdb-wal-max-batch-bytes setting.
	static const uint64_t max_batch_bytes_hard_limit = 1ULL << 30;	// 1 GiB

	// Byte budget for one get_updates_since() fetch on the streaming
	// side. Bounds the memory held while draining a large WAL backlog;
	// the client loops until the backlog is exhausted.
	static const uint64_t fetch_chunk_bytes = 64ULL << 20;	// 64 MiB

protected:
	enum server_mode {
		mode_none = 0,
		mode_begin,
		mode_seed,
	};

	storage*	_storage;
	cluster*	_cluster;             // destination-side topology check (may be NULL)
	server_mode	_server_mode;
	uint64_t	_seed_lsn;            // seed subcommand argument
	string		_client_source_id;    // source id (source's own master_id) sent by the source
	string		_server_source_id;    // source id echoed back in a mismatch reply
	client_result _client_result;
	bool		_connection_dirty;    // response stream left unsynchronized

	// Streaming throttle configuration, applied on the client
	// (source/sender) side. Set by handler_dump_replication before
	// run_client_push(); defaults are "no limit".
	uint64_t	_max_batch_bytes;   // 0 = unlimited
	int			_bwlimit_kbps;      // 0 = no rate limit
	int			_interval_usec;     // 0 = no per-batch sleep

public:
	op_repl_sync_wal(shared_connection c, storage* st, cluster* cl = NULL);
	virtual ~op_repl_sync_wal();

	// Entry points on the source side. `source_id` is this source's own
	// master_id — the identity of its WAL sequence domain.
	// run_client_push() negotiates the dest's position and streams the
	// WAL delta; run_client_seed() records source + position on the
	// dest after a full dump.
	virtual int run_client_push(const string& source_id);
	virtual int run_client_seed(const string& source_id, uint64_t lsn);

	// Result inspectors populated after run_client_push() returns.
	client_result get_client_result() const { return this->_client_result; }
	const string& get_server_source_id() const { return this->_server_source_id; }

	// True when a failure left unread/unwritten protocol data on the
	// connection; the caller must reconnect before reusing it.
	bool connection_dirty() const { return this->_connection_dirty; }

	// Streaming throttle configuration (client side).
	void set_max_batch_bytes(uint64_t n) { this->_max_batch_bytes = n; }
	void set_wal_sync_bwlimit(int kbps)  { this->_bwlimit_kbps    = kbps; }
	void set_wal_sync_interval(int usec) { this->_interval_usec   = usec; }

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();

	// True if a graceful shutdown of this thread has been requested.
	// Safe when no thread is attached (unit tests) — returns false.
	bool _shutdown_requested() {
		return this->_thread_available && this->_thread
			&& this->_thread->is_shutdown_request();
	}

	// Cap on get_updates_since() fetch iterations in one push before a
	// non-converging catch-up (write rate persistently above the
	// throttled send rate) is abandoned in favor of a full dump.
	static const int max_fetch_iterations = 64;

#ifdef HAVE_LIBROCKSDB
	int _run_server_begin(storage_rocksdb* rocksdb);
	int _run_server_seed(storage_rocksdb* rocksdb);
	int _receive_batches(storage_rocksdb* rocksdb, uint64_t& last_applied,
		bool& aborted, string& fail_reason);
	int _stream_batches(storage_rocksdb* rocksdb, uint64_t dest_lsn);
	int _abort_stream(const char* reason);
	int _read_final_result();
#endif
};

}	// namespace flare
}	// namespace gree

#endif	// OP_REPL_SYNC_WAL_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
