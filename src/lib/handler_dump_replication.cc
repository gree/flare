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
 *	handler_dump_replication.cc
 *
 *	implementation of gree::flare::handler_dump_replication
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */

#include "handler_dump_replication.h"
#include "connection_tcp.h"
#include "op_set.h"
#include <inttypes.h>

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_dump_replication
 */
handler_dump_replication::handler_dump_replication(shared_thread t, cluster* cl, storage* st, string server_name, int server_port):
		thread_handler(t),
		_cluster(cl),
		_storage(st),
		_replication_server_name(server_name),
		_replication_server_port(server_port),
		_bwlimitter() {
}

/**
 *	dtor for handler_dump_replication
 */
handler_dump_replication::~handler_dump_replication() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_dump_replication::run() {
	this->_thread->set_peer(this->_replication_server_name, this->_replication_server_port);
	this->_thread->set_state("connect");

	shared_connection c(new connection_tcp(
			   this->_replication_server_name, this->_replication_server_port));
	this->_connection = c;
	if (c->open() < 0) {
		log_err("failed to connect to cluster replication server (name=%s, port=%d)",
				   this->_replication_server_name.c_str(), this->_replication_server_port);
		return -1;
	}

	this->_thread->set_state("execute");
	this->_thread->set_op("dump");

	if (this->_storage->iter_begin() < 0) {
		log_err("database busy", 0);
		return -1;
	}

	key_resolver* kr = this->_cluster->get_key_resolver();
	cluster::node n = this->_cluster->get_node(this->_cluster->get_server_name(), this->_cluster->get_server_port());
	int partition = n.node_partition;
	int partition_size = this->_cluster->get_node_partition_map_size();
	int wait = this->_cluster->get_reconstruction_interval();
	this->_bwlimitter.set_bwlimit(static_cast<u_int64_t>(this->_cluster->get_reconstruction_bwlimit()));

	log_notice("starting dump replication (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
			   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, this->_bwlimitter.get_bwlimit());
	storage::entry e;
	storage::iteration i;
	while ((i = this->_storage->iter_next(e.key)) == storage::iteration_continue
			&& this->_thread && !this->_thread->is_shutdown_request()) {
		if (partition >= 0) {
			partition_size = this->_cluster->get_node_partition_map_size();
			int key_hash_value = e.get_key_hash_value(this->_cluster->get_key_hash_algorithm());
			int p = kr->resolve(key_hash_value, partition_size);
			if (p != partition) {
				log_debug("skipping entry (key=%s, key_hash_value=%d, mod=%d, partition=%d, partition_size=%d)",
						   e.key.c_str(), key_hash_value, p, partition, partition_size);
				continue;
			}
		}

		storage::result r;
		if (this->_storage->get(e, r) < 0) {
			if (r == storage::result_not_found) {
				log_info("skipping entry [key not found (perhaps expired)] (key=%s)", e.key.c_str());
			} else {
				log_err("skipping entry [get() error] (key=%s)", e.key.c_str());
			}
			continue;
		}

		// replicate
		op_set* p = new op_set(this->_connection, NULL, NULL);
		if (p->run_client(e) < 0) {
			delete p;
			break;
		}

		delete p;

		// wait
		long elapsed_usec = this->_bwlimitter.sleep_for_bwlimit(e.size);
		if (wait > 0 && wait-elapsed_usec > 0) {
			log_debug("wait for %d usec", wait);
			usleep(wait-elapsed_usec);
		}
	}

	this->_storage->iter_end();
	if (!this->_thread->is_shutdown_request()) {
		log_notice("dump replication completed (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%" PRIu64 ")",
				   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, this->_bwlimitter.get_bwlimit());
	} else {
		this->_thread->set_state("shutdown");
		log_warning("dump replication interruptted (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%" PRIu64 ")",
				   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, this->_bwlimitter.get_bwlimit());
	}
	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
