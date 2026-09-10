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
 *	op_stats_node.cc
 *	
 *	implementation of gree::flare::op_stats_node
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flared.h"
#include "op_stats_node.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_stats_node
 */
op_stats_node::op_stats_node(shared_connection c):
		op_stats(c) {
}

/**
 *	dtor for op_stats_node
 */
op_stats_node::~op_stats_node() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_stats_node::_parse_text_server_parameters() {
	int r = op_stats::_parse_text_server_parameters();

	return r;
}

int op_stats_node::_run_server() {
	switch (this->_stats_type) {
	case stats_type_items:
		this->_send_stats_items();
		break;
	case stats_type_slabs:
		this->_send_stats_slabs();
		break;
	case stats_type_sizes:
		this->_send_stats_sizes();
		break;
	case stats_type_threads:
		this->_send_stats_threads(singleton<flared>::instance().get_req_thread_pool(), singleton<flared>::instance().get_other_thread_pool());
		break;
	case stats_type_threads_request:
		this->_send_stats_threads(singleton<flared>::instance().get_req_thread_pool(), singleton<flared>::instance().get_other_thread_pool(), thread_pool::thread_type_request);
		break;
	case stats_type_threads_slave:
		{
			cluster* cl = singleton<flared>::instance().get_cluster();
			vector<cluster::node> slave = cl->get_slave_node();
			for (vector<cluster::node>::iterator it = slave.begin(); it != slave.end(); it++) {
				this->_send_stats_threads(singleton<flared>::instance().get_req_thread_pool(), singleton<flared>::instance().get_other_thread_pool(), it->node_thread_type);
			}
		}
		break;
	case stats_type_nodes:
		this->_send_stats_nodes(singleton<flared>::instance().get_cluster());
		break;
	case stats_type_threads_queue:
		this->_send_stats_threads_queue();
		break;
	default:
		this->_send_stats(singleton<flared>::instance().get_req_thread_pool(),singleton<flared>::instance().get_other_thread_pool(),
				singleton<flared>::instance().get_storage(),
				singleton<flared>::instance().get_cluster());
		// APPLIED cluster-replication state (not the config file's desired
		// state): the operator level-triggers on the difference — a SIGHUP
		// that raced the ConfigMap mount propagation leaves flared running
		// the old config with no observable signal otherwise (a lost
		// re-signal once kept a stream configured-but-dead for 107 min,
		// and the reverse, configured-off-but-streaming, on a live stop).
		{
			shared_cluster_replication repl = singleton<flared>::instance().get_cluster_replication();
			if (repl) {
				this->_send_stat("cluster_replication", repl->is_started() ? "on" : "off");
				if (repl->is_started()) {
					this->_send_stat("cluster_replication_mode", cluster_replication::mode_cast(repl->get_mode()));
					char repl_dest[BUFSIZ];
					snprintf(repl_dest, sizeof(repl_dest), "%s:%d", repl->get_server_name().c_str(), repl->get_server_port());
					this->_send_stat("cluster_replication_destination", repl_dest);
				}
			}
		}
		break;
	}
	this->_send_result(result_end);

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
