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
 *	op_repl_snapshot.h
 *
 *	Physical reseed = "snapshot + WAL catch-up" bootstrap.
 *
 *	A reconstructing SLAVE (client side) pulls a consistent RocksDB
 *	checkpoint from its source (server side) as raw files, swaps it in as
 *	its live DB and seeds the replication cursor to the checkpoint's exact
 *	sequence number; the follow-up incremental WAL sync then ships only
 *	the delta. Compared to the logical full dump this transfers
 *	pre-compacted SST/blob files at network speed, generates NO write-path
 *	WAL churn on the receiver, and inherits the source's lineage token
 *	automatically (it travels inside the checkpoint as a reserved key).
 *
 *	Wire protocol (client → server, then server → client):
 *	  "repl_snapshot\r\n"
 *	  "SNAPSHOT <checkpoint_seq> <master_id> <nfiles>\r\n"
 *	  nfiles × ( "FILE <name> <size>\r\n" + <size> raw bytes )
 *	  "END\r\n"
 *	Errors: "SERVER_ERROR <msg>\r\n" at any line boundary.
 */
#ifndef	OP_REPL_SNAPSHOT_H
#define	OP_REPL_SNAPSHOT_H

#include "op.h"
#include <boost/function.hpp>
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

class op_repl_snapshot : public op {
protected:
	storage*			_storage;
	uint64_t			_bwlimit;					// KB/s: client's requested cap, sent with the request (0 = no preference)
	uint64_t			_peer_bwlimit_request;		// KB/s: server side — what the client asked for
	// R3-D: evaluated right before the swap replaces the local copy; false
	// refuses the swap (the staged copy is removed, the local copy is kept)
	boost::function<bool (string&)>	_pre_swap_gate;
	// COPY RETENTION (design §3.1): receive into this EXISTING empty
	// directory (data_dir/staging-<attempt>) and stop there — no gate, no
	// swap; the caller verifies and switches. "" = the legacy swap.
	string				_receive_dir;
	uint64_t			_received_seq;
	bool				_busy;		// the source answered busy (one serve at a time)
	string				_received_master_id;
	// checked between files and every kSpaceWatchBytes; false stops the transfer
	boost::function<bool (string&)>	_space_watch;

public:
	op_repl_snapshot(shared_connection c, storage* st);
	virtual ~op_repl_snapshot();

	void set_bwlimit(uint64_t bwlimit) { this->_bwlimit = bwlimit; };
	void set_pre_swap_gate(boost::function<bool (string&)> g) { this->_pre_swap_gate = g; };
	void set_receive_dir(const string& d) { this->_receive_dir = d; };
	void set_space_watch(boost::function<bool (string&)> w) { this->_space_watch = w; };
	uint64_t get_received_seq() const { return this->_received_seq; };
	bool is_busy() const { return this->_busy; };
	string get_received_master_id() const { return this->_received_master_id; };
	static const uint64_t kSpaceWatchBytes = 64ULL << 20;

	// Pull the snapshot from the connected source and swap it in as the
	// local live DB (rocksdb only). Returns 0 on success; on any failure the
	// caller falls back to the legacy truncate+full-dump path.
	virtual int run_client();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_REPL_SNAPSHOT_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
