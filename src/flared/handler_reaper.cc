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
 *	handler_reaper.cc
 *
 *	implementation of gree::flare::handler_reaper
 */
#include "handler_reaper.h"
#include "op_delete.h"
#include "ini_option.h"

#include <unistd.h>

namespace gree {
namespace flare {

// {{{ ctor/dtor
handler_reaper::handler_reaper(shared_thread t, cluster* cl, storage* st):
		thread_handler(t),
		_cluster(cl),
		_storage(st) {
}

handler_reaper::~handler_reaper() {
}
// }}}

// {{{ public methods
/**
 *	run thread proc
 */
int handler_reaper::run() {
	this->_thread->set_state("wait");
	this->_thread->set_op("");

	for (;;) {
		// Pace the sweeps. Re-read the interval each cycle so a SIGHUP that
		// changes it takes effect. Sleep in 1s steps so shutdown stays
		// responsive even with a long interval.
		int interval = ini_option_object().get_reap_expired_interval();
		if (interval < 1) {
			interval = 1;
		}
		if (!this->_sleep_interruptible(interval)) {
			this->_thread->set_state("shutdown");
			break;
		}

		if (!ini_option_object().is_reap_expired()) {
			continue;                                  // crawler disabled
		}
		if (this->_storage == NULL || this->_storage->get_type() != storage::type_rocksdb) {
			continue;                                  // only meaningful for the WAL backend
		}
		if (!this->_is_reap_target()) {
			continue;                                  // not the (active) master -> the master reaps and replicates
		}

		this->_thread->set_state("execute");
		this->_thread->set_op("reap_expired");

		time_t now = stats_object->get_timestamp();
		uint32_t max_scan = static_cast<uint32_t>(ini_option_object().get_reap_expired_chunk_size());
		if (max_scan == 0) {
			max_scan = 1;
		}
		int chunk_sleep_msec = ini_option_object().get_reap_expired_chunk_sleep_msec();

		string after = "";
		bool more = true;
		uint64_t total_scanned = 0;
		uint64_t total_reaped = 0;
		uint64_t total_replicated = 0;
		bool aborted = false;

		while (more) {
			if (this->_thread->is_shutdown_request()) {
				aborted = true;
				break;
			}
			// Re-check ownership between chunks: if we lost mastership mid-sweep
			// (failover), stop issuing deletes immediately.
			if (!this->_is_reap_target()) {
				aborted = true;
				break;
			}

			uint32_t scanned = 0;
			uint32_t reaped = 0;
			string last;
			vector<storage::entry> reaped_entries;
			if (this->_storage->reap_expired(now, max_scan, after, last, more, scanned, reaped, &reaped_entries) < 0) {
				log_warning("reap_expired failed (after=%s) -> aborting this sweep", after.c_str());
				aborted = true;
				break;
			}
			total_scanned += scanned;
			total_reaped += reaped;
			after = last;
			// Replicate every key we just deleted to this partition's slaves (and,
			// through the proxy event listeners, to a cluster-replication
			// destination) as a VERSION-CARRYING delete — the same wire op a
			// client delete produces. Without this the reap stayed master-local
			// (observed live: the slave carried ~10k more keys than its master).
			for (vector<storage::entry>::const_iterator it = reaped_entries.begin(); it != reaped_entries.end(); it++) {
				if (this->_replicate_delete(*it) == 0) {
					total_replicated++;
				}
			}

			if (more && chunk_sleep_msec > 0) {
				usleep(static_cast<useconds_t>(chunk_sleep_msec) * 1000);
			}
		}

		// Only log sweeps that actually reaped something. A sweep that scans the
		// keyspace and deletes nothing (the common case) stays silent so we don't
		// emit a line every interval forever; the scanned count is still visible
		// at debug level.
		if (total_reaped > 0) {
			log_info("reap_expired sweep done (reaped=%llu, replicated=%llu, scanned=%llu, aborted=%d)",
					(unsigned long long)total_reaped,
					(unsigned long long)total_replicated,
					(unsigned long long)total_scanned,
					aborted ? 1 : 0);
		} else {
			log_debug("reap_expired sweep done (reaped=0, scanned=%llu, aborted=%d)",
					(unsigned long long)total_scanned,
					aborted ? 1 : 0);
		}

		this->_thread->set_state("wait");
		this->_thread->set_op("");
	}

	return 0;
}
// }}}

// {{{ protected methods
/**
 *	true iff this node is the ACTIVE master of a partition — the only role that
 *	may issue reaping deletes (each one is then forwarded to the slaves as a
 *	version-carrying proxied delete, see _replicate_delete).
 */
bool handler_reaper::_is_reap_target() {
	if (this->_cluster == NULL) {
		return false;
	}
	cluster::node self = this->_cluster->get_node(
			this->_cluster->get_server_name(),
			this->_cluster->get_server_port());
	return self.node_role == cluster::role_master
			&& self.node_state == cluster::state_active
			&& self.node_partition >= 0;
}

/**
 *	sleep for `seconds`, waking early on a shutdown request. returns false if a
 *	shutdown was requested (caller should stop), true otherwise.
 */
bool handler_reaper::_sleep_interruptible(int seconds) {
	for (int i = 0; i < seconds; i++) {
		if (this->_thread->is_shutdown_request()) {
			return false;
		}
		sleep(1);
	}
	return !this->_thread->is_shutdown_request();
}
// }}}

/**
 *	forward one reaped key to the partition's slaves as a version-carrying
 *	delete — the SAME thing op_delete::_run_server does after a client delete
 *	is applied locally: cluster::post_proxy_write fans the op out to every
 *	slave (and lets the proxy event listeners mirror it to a cluster-
 *	replication destination). The version is the one the master deleted at,
 *	so a slave applies it under remove()'s default rule — a delete older than
 *	the slave's current version is ignored — and a newer set that raced ahead
 *	is never clobbered. noreply/async: the sweep must not block per key.
 *	Never call pre_proxy_write here: that would ROUTE the key to whatever
 *	partition currently owns it, which for a not-yet-purged orphan would be a
 *	foreign master holding a LIVE copy.
 */
int handler_reaper::_replicate_delete(const storage::entry& reaped) {
	if (this->_cluster == NULL) {
		return -1;
	}
	op_delete op(shared_connection(), this->_cluster, this->_storage);
	storage::entry& e = op.get_entry();
	e.key = reaped.key;
	e.version = reaped.version;
	e.expire = 0;
	e.option = storage::option_noreply;
	cluster::proxy_request r = this->_cluster->post_proxy_write(&op, false);
	if (r == cluster::proxy_request_error_partition || r == cluster::proxy_request_error_enqueue) {
		log_warning("reap replicate failed (key=%s, version=%u, r=%d)", reaped.key.c_str(), reaped.version, static_cast<int>(r));
		return -1;
	}
	return 0;
}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
