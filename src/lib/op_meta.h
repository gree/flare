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
 *	op_meta.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_META_H
#define	OP_META_H

#include "op.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (meta)
 */
class op_meta : public op {
protected:
	cluster*	_cluster;
	storage*	_storage;
	string		_meta_key;  // "features" for capability negotiation, empty for cluster metadata
	// Peer advertised the snapshot-bootstrap op (repl_snapshot) in its
	// features reply. Populated by any run_client_features() call.
	bool			_peer_snapshot_supported;
	bool			_peer_snapshot_push_supported;

public:
	op_meta(shared_connection c, cluster* cl, storage* st = NULL);
	virtual ~op_meta();

	virtual int run_client(int& partition_size, storage::hash_algorithm& key_hash_algorithm, key_resolver::type& key_resolver_type, int& key_resolver_modular_hint, int& key_resolver_modular_virtual);
	virtual int run_client_features(bool& rocksdb_wal_supported);
	// Extended features probe that also returns the server's master
	// identity token. Empty string means "server did not advertise a
	// token" (e.g. non-RocksDB backend or older flared).
	virtual int run_client_features(bool& rocksdb_wal_supported, string& master_id);
	// Full features probe that also returns the server's current RocksDB
	// sequence number (latest_lsn). 0 means "server did not advertise one"
	// (non-RocksDB backend or older flared that predates the token).
	virtual int run_client_features(bool& rocksdb_wal_supported, string& master_id, uint64_t& latest_lsn);
	bool get_peer_snapshot_supported() const { return this->_peer_snapshot_supported; };
	bool get_peer_snapshot_push_supported() const { return this->_peer_snapshot_push_supported; };

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client();
	virtual int _run_client_features();
	virtual int _parse_text_client_parameters(int& partition_size, storage::hash_algorithm& key_hash_algorithm, key_resolver::type& key_resolver_type, int& key_resolver_modular_hint, int& key_resolver_modular_virtual);
	virtual int _parse_text_client_features(bool& rocksdb_wal_supported, string& master_id, uint64_t& latest_lsn);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_META_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
