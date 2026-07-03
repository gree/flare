/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 */
/**
 *	op_orphan_purge.cc
 *
 *	implementation of gree::flare::op_orphan_purge
 */
#include "op_orphan_purge.h"
#include "key_resolver.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

namespace gree {
namespace flare {

// {{{ ctor/dtor
op_orphan_purge::op_orphan_purge(shared_connection c, cluster* cl, storage* st):
		op(c, "orphan_purge"),
		_cluster(cl),
		_storage(st),
		_token("") {
}

op_orphan_purge::~op_orphan_purge() {
}
// }}}

// {{{ protected methods
int op_orphan_purge::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (q[0] == '\0') {
		log_warning("orphan_purge: missing token argument", 0);
		delete[] p;
		return -1;
	}
	this->_token = q;
	// Drop trailing whitespace tokens.
	util::next_word(p+n, q, sizeof(q));
	if (q[0] != '\0') {
		log_notice("bogus parameter: %s -> ignoring", q);
	}
	delete[] p;
	return 0;
}

int op_orphan_purge::_run_server() {
#ifdef HAVE_LIBROCKSDB
	if (!this->_storage || this->_storage->get_type() != storage::type_rocksdb) {
		return this->_send_result(result_server_error, "not_supported");
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rdb || !this->_cluster) {
		return this->_send_result(result_server_error, "internal_error");
	}

	// Validate the token against the outstanding scan.
	log_info("orphan_purge starting (token=%s)", this->_token.c_str());
	storage_rocksdb::orphan_scan_token scan;
	if (!rdb->lookup_orphan_scan(this->_token, scan)) {
		log_warning("orphan_purge: token invalid or expired (token=%s)", this->_token.c_str());
		return this->_send_result(result_server_error, "invalid_token");
	}
	log_info("orphan_purge: token validated (scan_count=%llu, scan_bytes=%llu, scan_nmv=%llu)",
		(unsigned long long)scan.orphan_count,
		(unsigned long long)scan.orphan_bytes,
		(unsigned long long)scan.node_map_version);

	// Require topology stability: if the cluster's node_map_version
	// has moved since the scan, orphan judgments might no longer
	// hold, so we refuse and require a fresh scan.
	uint64_t nmv_now = this->_cluster->get_node_map_version();
	if (nmv_now != scan.node_map_version) {
		log_warning("orphan_purge: node_map_version changed (scan=%llu now=%llu) -> refuse",
			(unsigned long long)scan.node_map_version,
			(unsigned long long)nmv_now);
		rdb->clear_orphan_scan();  // invalidate stale token
		return this->_send_result(result_server_error, "topology_changed");
	}

	// Walk again, delete orphans. We intentionally do NOT trust the
	// count recorded by the scan for the actual delete decisions —
	// each key is re-evaluated against the current resolver, and
	// reserved metadata keys are skipped at the storage layer
	// regardless. The scan count is used only for reporting.
	key_resolver* kr = this->_cluster->get_key_resolver();
	cluster::node self = this->_cluster->get_node(
		this->_cluster->get_server_name(),
		this->_cluster->get_server_port());
	int partition      = self.node_partition;
	int partition_size = this->_cluster->get_node_partition_map_size();

	if (partition < 0) {
		return this->_send_result(result_server_error, "no_partition");
	}

	// A node in state_prepare/state_ready has its partition in the
	// PREPARE map only; the active map (partition_size / resolve())
	// does not include it, so every local key would resolve to another
	// partition and the purge would wipe the entire dataset while the
	// node is still being reconstructed. Refuse unless the node is
	// fully active in the current partition map.
	if (self.node_state != cluster::state_active || partition >= partition_size) {
		log_warning("orphan_purge refused: node is not active in the current partition map (state=%d, partition=%d, partition_size=%d)",
			self.node_state, partition, partition_size);
		rdb->clear_orphan_scan();  // a token issued in this state must not survive
		return this->_send_result(result_server_error, "not_active");
	}

	if (this->_storage->iter_begin() < 0) {
		return this->_send_result(result_server_error, "iter_failed");
	}

	uint64_t deleted = 0;
	storage::entry e;
	storage::iteration it;
	while ((it = this->_storage->iter_next(e.key)) == storage::iteration_continue) {
		int h = e.get_key_hash_value(this->_cluster->get_key_hash_algorithm());
		int p = kr->resolve(h, partition_size);
		if (p == partition) {
			continue;
		}
		storage::result r;
		storage::entry del;
		del.key = e.key;
		del.version = 0;
		if (this->_storage->remove(del, r, storage::behavior_skip_version) == 0) {
			if (r == storage::result_deleted) {
				deleted++;
				log_debug("orphan_purge: deleted key=%s (resolved_partition=%d, my_partition=%d)",
					e.key.c_str(), p, partition);
			}
		}
	}
	this->_storage->iter_end();

	// Consume the token: a successful purge must not be replayable.
	rdb->clear_orphan_scan();

	char line[BUFSIZ];
	snprintf(line, sizeof(line), "STAT orphan_purge_deleted %llu\r\n",
		(unsigned long long)deleted);
	this->_connection->write(line, strlen(line));
	snprintf(line, sizeof(line), "STAT orphan_purge_scan_count %llu\r\n",
		(unsigned long long)scan.orphan_count);
	this->_connection->write(line, strlen(line));

	log_notice("orphan_purge complete (deleted=%llu scan_count=%llu)",
		(unsigned long long)deleted,
		(unsigned long long)scan.orphan_count);

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
