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
 */
/**
 *	op_orphan_scan.cc
 *
 *	implementation of gree::flare::op_orphan_scan
 */
#include "op_orphan_scan.h"
#include "key_resolver.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

namespace gree {
namespace flare {

// {{{ ctor/dtor
op_orphan_scan::op_orphan_scan(shared_connection c, cluster* cl, storage* st):
		op(c, "orphan_scan"),
		_cluster(cl),
		_storage(st) {
}

op_orphan_scan::~op_orphan_scan() {
}
// }}}

// {{{ protected methods
int op_orphan_scan::_parse_text_server_parameters() {
	// No arguments. Any trailing garbage is tolerated but logged.
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	char q[BUFSIZ];
	util::next_word(p, q, sizeof(q));
	if (q[0] != '\0') {
		log_notice("bogus parameter: %s -> ignoring", q);
	}
	delete[] p;
	return 0;
}

int op_orphan_scan::_run_server() {
#ifdef HAVE_LIBROCKSDB
	if (!this->_storage || this->_storage->get_type() != storage::type_rocksdb) {
		log_warning("orphan_scan requested but storage is not RocksDB", 0);
		return this->_send_result(result_server_error, "not_supported");
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rdb || !this->_cluster) {
		return this->_send_result(result_server_error, "internal_error");
	}

	// Snapshot topology up-front so the scan works against a
	// consistent view. If the node_map_version changes during the
	// walk we invalidate the scan result, because an orphan judgment
	// only makes sense against a single topology.
	key_resolver* kr = this->_cluster->get_key_resolver();
	cluster::node self = this->_cluster->get_node(
		this->_cluster->get_server_name(),
		this->_cluster->get_server_port());
	int partition      = self.node_partition;
	int partition_size = this->_cluster->get_node_partition_map_size();
	uint64_t nmv_start = this->_cluster->get_node_map_version();

	log_info("orphan_scan starting (partition=%d, partition_size=%d, node_map_version=%llu, master_id=%s)",
		partition, partition_size, (unsigned long long)nmv_start, rdb->get_master_id().c_str());

	if (partition < 0) {
		// Node is not currently assigned to a partition (proxy,
		// down). Every local key is, by definition, an orphan — but
		// in that state the operator should NOT be purging, so we
		// refuse and let them figure out the right move.
		log_warning("orphan_scan refused: node has no partition assignment (role/state transient)", 0);
		return this->_send_result(result_server_error, "no_partition");
	}

	// A node in state_prepare/state_ready has a partition assignment in
	// the PREPARE partition map, which the active map (and therefore
	// partition_size / resolve()) does not include yet — every local
	// key would be judged an orphan and a purge would wipe the entire
	// dataset mid-reconstruction. Only a fully active node whose
	// partition exists in the active map may scan.
	if (self.node_state != cluster::state_active || partition >= partition_size) {
		log_warning("orphan_scan refused: node is not active in the current partition map (state=%d, partition=%d, partition_size=%d)",
			self.node_state, partition, partition_size);
		return this->_send_result(result_server_error, "not_active");
	}

	if (this->_storage->iter_begin() < 0) {
		log_err("orphan_scan: iter_begin failed", 0);
		return this->_send_result(result_server_error, "iter_failed");
	}

	uint64_t scanned = 0;
	uint64_t orphan_count = 0;
	uint64_t orphan_bytes = 0;

	storage::entry e;
	storage::iteration it;
	while ((it = this->_storage->iter_next(e.key)) == storage::iteration_continue) {
		scanned++;
		int h = e.get_key_hash_value(this->_cluster->get_key_hash_algorithm());
		int p = kr->resolve(h, partition_size);
		if (p != partition) {
			orphan_count++;
			// Fetch just the entry header to learn the byte size
			// (cheap: RocksDB will read from block cache almost
			// always for recently-scanned keys).
			storage::entry body;
			body.key = e.key;
			storage::result r;
			if (this->_storage->get(body, r, 0) == 0 && r == storage::result_none) {
				orphan_bytes += body.size;
			}
		}
	}
	this->_storage->iter_end();

	uint64_t nmv_end = this->_cluster->get_node_map_version();
	if (nmv_start != nmv_end) {
		log_warning("orphan_scan: node_map_version changed during scan (%llu -> %llu) -> result discarded",
			(unsigned long long)nmv_start, (unsigned long long)nmv_end);
		return this->_send_result(result_server_error, "topology_changed");
	}

	string token = rdb->remember_orphan_scan(nmv_start, orphan_count, orphan_bytes);

	// Emit a memcached-flavored STAT stream so the client parses it
	// with the same machinery as `stats`.
	char line[BUFSIZ];
	snprintf(line, sizeof(line), "STAT orphan_scan_token %s\r\n", token.c_str());
	this->_connection->write(line, strlen(line));
	snprintf(line, sizeof(line), "STAT orphan_scan_node_map_version %llu\r\n",
		(unsigned long long)nmv_start);
	this->_connection->write(line, strlen(line));
	snprintf(line, sizeof(line), "STAT orphan_scan_scanned_keys %llu\r\n",
		(unsigned long long)scanned);
	this->_connection->write(line, strlen(line));
	snprintf(line, sizeof(line), "STAT orphan_scan_orphan_count %llu\r\n",
		(unsigned long long)orphan_count);
	this->_connection->write(line, strlen(line));
	snprintf(line, sizeof(line), "STAT orphan_scan_orphan_bytes %llu\r\n",
		(unsigned long long)orphan_bytes);
	this->_connection->write(line, strlen(line));
	snprintf(line, sizeof(line), "STAT orphan_scan_partition %d\r\n", partition);
	this->_connection->write(line, strlen(line));

	log_notice("orphan_scan complete (scanned=%llu orphans=%llu bytes=%llu token=%s)",
		(unsigned long long)scanned,
		(unsigned long long)orphan_count,
		(unsigned long long)orphan_bytes,
		token.c_str());

	return this->_send_result(result_end);
#else
	(void)this->_cluster;
	(void)this->_storage;
	return this->_send_result(result_server_error, "not_compiled");
#endif
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
