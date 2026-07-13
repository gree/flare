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
	const string				_node_server_name;
	const int						_node_server_port;
	int									_partition;
	int									_partition_size;
	cluster::role				_role;
	int									_reconstruction_interval;
	int									_reconstruction_bwlimit;

public:
	handler_reconstruction(shared_thread t, cluster* cl, storage* st, string node_server_name, int node_server_port, int partition, int partition_size, cluster::role r, int reconstruction_interval, int reconstruction_bwlimit);
	virtual ~handler_reconstruction();

	virtual int run();

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
	bool _try_wal_reconstruction(shared_connection c, bool& peer_wal_supported, string& peer_master_id, uint64_t& peer_latest_lsn, bool& peer_reachable);

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
