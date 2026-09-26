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
 *	WAL-based incremental replication for RocksDB
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

/**
 *	opcode class (repl_sync_wal)
 */
class op_repl_sync_wal : public op {
public:
	// Reason a client-side run ended. Used by the caller to decide
	// whether to fall back to a full dump and whether to adopt a new
	// master identity token after that dump.
	enum client_result {
		client_success          = 0,
		client_not_supported    = 1,  // server doesn't speak this op
		client_lsn_purged       = 2,  // slave too far behind
		client_lsn_ahead        = 3,  // slave newer than master
		client_master_id_mismatch = 4,// different lineage
		client_server_error     = 5,  // any other server-side failure
		client_apply_error      = 6,  // slave failed to apply a batch
		client_protocol_error   = 7,  // unparseable response
	};

protected:
	storage*	_storage;
	uint64_t	_lsn;
	string		_client_master_id;    // master_id the slave claims to follow
	string		_server_master_id;    // master_id extracted from a mismatch reply
	client_result _client_result;

	// Server-side throttling configuration. Set by the handler
	// before _run_server() runs; defaults are "no limit" so unit
	// tests that construct this op directly are unaffected.
	uint64_t	_max_batch_bytes;   // 0 = unlimited
	int			_bwlimit_kbps;      // 0 = no rate limit
	int			_interval_usec;     // 0 = no per-batch sleep

public:
	op_repl_sync_wal(shared_connection c, storage* st);
	virtual ~op_repl_sync_wal();

	// Entry point on the slave side. `lsn` is the slave's last applied
	// sequence number and `master_id` is the identity token the slave
	// believes its master has. An empty token means "I have no prior
	// lineage, treat me as fresh".
	virtual int run_client(uint64_t lsn, const string& master_id);

	// Result inspectors populated after run_client() returns.
	client_result get_client_result() const { return this->_client_result; }
	const string& get_server_master_id() const { return this->_server_master_id; }

	// Server-side throttling configuration. These are applied only
	// on the streaming side (`_run_server`); receiving side is a
	// no-op for these settings.
	void set_max_batch_bytes(uint64_t n) { this->_max_batch_bytes = n; }
	void set_wal_sync_bwlimit(int kbps)  { this->_bwlimit_kbps    = kbps; }
	void set_wal_sync_interval(int usec) { this->_interval_usec   = usec; }

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(uint64_t lsn, const string& master_id);
	virtual int _parse_text_client_parameters();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_REPL_SYNC_WAL_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
