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
 *	op_repl_snapshot_push.h
 *
 *	Physical INITIAL TRANSFER for cluster replication (source → destination
 *	cluster with the SAME partition count).
 *
 *	The intra-cluster snapshot bootstrap (op_repl_snapshot) is a PULL by the
 *	reconstructing slave; cluster replication pushes from the source master,
 *	so this op inverts the roles: the SOURCE (client) connects to the
 *	destination cluster and pushes a checkpoint + WAL tail; the DESTINATION
 *	node (server) receives, verifies and swaps it in.
 *
 *	Wire protocol (client = source partition master):
 *	  C: "repl_snapshot_push <partition> <partition_size> <bwlimit_kbps>\r\n"
 *	  S: "REDIRECT <host> <port>\r\n"       (receiver is not that partition's
 *	                                         master — reconnect there)
 *	   | "SERVER_ERROR <reason>\r\n"        (declined: partition count mismatch,
 *	                                         destination not fresh, ...)
 *	   | "OK\r\n"
 *	  C: "SNAPSHOT <checkpoint_seq> <master_id> <nfiles>\r\n"
 *	     nfiles × ( "FILE <name> <size> <crc32>\r\n" + raw bytes )
 *	     "END\r\n"
 *	  S: "SWAPPED\r\n"                      (files verified + swapped in)
 *	  C: repeated "WBATCH <lsn> <size>\r\n" + raw WriteBatch bytes — the WAL
 *	     tail since <checkpoint_seq>, closing the gap between the checkpoint
 *	     and the swap (live duplicate writes delivered before the swap were
 *	     wiped BY the swap; they are all in this range because everything on
 *	     the wire originated on the source) — then "WEND\r\n"
 *	  S: "STORED <applied>\r\n"
 *
 *	WAL-retention independence: the source holds RocksDB
 *	DisableFileDeletions() from just before the checkpoint until the WAL tail
 *	has been pushed, so the needed range can NOT be purged mid-transfer no
 *	matter how small wal-ttl/size caps are — the cost is source disk growth
 *	bounded by the transfer duration (bwlimit-bound; raise
 *	rocksdb-snapshot-bwlimit for large migrations).
 *
 *	Safety: the destination accepts only when it is FRESH (at most a few
 *	thousand keys — the live-duplicate trickle that lands between `enable` and
 *	this push; everything it wipes is by construction contained in the
 *	checkpoint ∪ WAL tail). A destination with real data declines and the
 *	source falls back to the legacy merge dump.
 */
#ifndef	OP_REPL_SNAPSHOT_PUSH_H
#define	OP_REPL_SNAPSHOT_PUSH_H

#include "op.h"
#include "cluster.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

class op_repl_snapshot_push : public op {
public:
	enum client_result {
		client_result_none = 0,
		client_result_success,
		client_result_redirect,
		client_result_declined,
		client_result_error,
	};

	// destinations holding more keys than this decline the push. Non-zero
	// because the live duplicate stream starts delivering the moment
	// replication is enabled, a moment before this op can arrive — those
	// keys all originated on the source and are recovered by the
	// checkpoint + WAL tail, so wiping them is safe.
	static const uint64_t fresh_destination_threshold = 4096;

protected:
	cluster*			_cluster;
	storage*			_storage;
	int					_partition;
	int					_partition_size;
	uint64_t			_bwlimit;			// KB/s the SOURCE throttles the file stream at
	client_result		_client_result;
	string				_redirect_host;
	int					_redirect_port;

public:
	op_repl_snapshot_push(shared_connection c, cluster* cl, storage* st);
	virtual ~op_repl_snapshot_push();

	void set_bwlimit(uint64_t bwlimit) { this->_bwlimit = bwlimit; };
	client_result get_client_result() const { return this->_client_result; };
	string get_redirect_host() const { return this->_redirect_host; };
	int get_redirect_port() const { return this->_redirect_port; };

	// SOURCE side: push this node's storage (its partition's data) into the
	// destination cluster. Returns 0 on success; on redirect, sets
	// client_result_redirect + redirect host/port and returns -1.
	virtual int run_client(int partition, int partition_size);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(int partition, int partition_size);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_REPL_SNAPSHOT_PUSH_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
