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
 *	handler_reconstruction.cc
 *
 *	implementation of gree::flare::handler_reconstruction
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "handler_reconstruction.h"
#include "connection_tcp.h"
#include "op_dump.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_reconstruction
 */
handler_reconstruction::handler_reconstruction(shared_thread t, cluster* cl, storage* st, string node_server_name, int node_server_port, int partition, int partition_size, cluster::role r, int reconstruction_interval, int reconstruction_bwlimit):
		thread_handler(t),
		_cluster(cl),
		_storage(st),
		_node_server_name(node_server_name),
		_node_server_port(node_server_port),
		_partition(partition),
		_partition_size(partition_size),
		_role(r),
		_reconstruction_interval(reconstruction_interval),
		_reconstruction_bwlimit(reconstruction_bwlimit) {
}

/**
 *	dtor for handler_reconstruction
 */
handler_reconstruction::~handler_reconstruction() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_reconstruction::run() {
	this->_thread->set_peer(this->_node_server_name, this->_node_server_port);
	this->_thread->set_state("connect");

	shared_connection c(new connection_tcp(this->_node_server_name, this->_node_server_port));
	this->_connection = c;
	if (c->open() < 0) {
		log_err("failed to connect to node server (name=%s, port=%d) -> deactivating node", this->_node_server_name.c_str(), this->_node_server_port);
		this->_cluster->deactivate_node();
		return -1;
	}

	op_dump* p = new op_dump(c, this->_cluster, this->_storage);

	p->set_thread(this->_thread);
	this->_thread->set_state("execute");
	this->_thread->set_op(p->get_ident());

	log_notice("starting dump operation (master=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
			   this->_node_server_name.c_str(), this->_node_server_port, this->_partition, this->_partition_size, this->_cluster->get_reconstruction_interval(), this->_cluster->get_reconstruction_bwlimit());

	if (p->run_client(this->_reconstruction_interval, this->_partition, this->_partition_size, this->_reconstruction_bwlimit) < 0) {
		log_err("failed to reconstruct (%s %s)", op::result_cast(p->get_result()).c_str(), p->get_result_message().c_str());
		delete p;
		this->_cluster->deactivate_node();
		return -1;
	}

	delete p;
	log_notice("dump completed (master=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
			   this->_node_server_name.c_str(), this->_node_server_port, this->_partition, this->_partition_size, this->_reconstruction_interval, this->_reconstruction_bwlimit);

	// node activation (state -> ready)
	if (this->_role == cluster::role_master) {
		int n = this->_cluster->notify_master_reconstruction();
		log_notice("master reconstruction completed (%d threads left)", n);
		if (n <= 0) {
			this->_cluster->activate_node();
		}
	} else {
		// just shift state to ready
		this->_cluster->activate_node(true);		// true: skip ready state
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
