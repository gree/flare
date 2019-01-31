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
 *	mock_cluster.cc
 *
 *	implementation of gree::flare::mock_cluster
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 */
#include "mock_cluster.h"
#include "key_resolver_modular.h"

#include <cppcutter.h>

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
mock_cluster::mock_cluster(string server_name, int server_port):
		cluster(NULL, NULL, server_name, server_port) {
	this->_key_hash_algorithm = storage::hash_algorithm_simple;
	this->_key_resolver = new key_resolver_modular(1024, 1, 4096);
	this->_key_resolver->startup();
}

mock_cluster::~mock_cluster() {
	this->clear_node_map();
	this->clear_node_partition_map();
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
cluster::partition mock_cluster::set_partition(int partition, node master, node slave[], int slave_num) {
	string node_key = this->to_node_key(master.node_server_name, master.node_server_port);
	cluster::partition p;
	p.master = this->_get_partition_node(master.node_server_name, master.node_server_port, master.node_balance);
	if (slave != NULL) {
		for (int i = 0; i < slave_num; i++) {
			p.slave.push_back(this->_get_partition_node(slave[i].node_server_name, slave[i].node_server_port, slave[i].node_balance));
		}
	}
	this->_node_partition_map[partition] = p;
	return p;
}

cluster::node mock_cluster::set_node(string server_name, int server_port, role r, state s, int partition, int balance) {
	string node_key = this->to_node_key(server_name, server_port);
	node n;
	n.node_server_name = server_name;
	n.node_server_port = server_port;
	n.node_role = r;
	n.node_state = s;
	n.node_partition = partition;
	n.node_balance = balance;
	n.node_thread_type = this->_thread_type;
	this->_node_map[node_key] = n;
	this->_thread_type++;
	return n;
}

void mock_cluster::clear_node_map() {
	this->_node_map.clear();
}

void mock_cluster::clear_node_partition_map() {
	for (node_partition_map::iterator it = this->_node_partition_map.begin();
			it != this->_node_partition_map.end(); it++) {
		it->second.slave.clear();
	}
	this->_node_partition_map.clear();
}

void mock_cluster::dump_node_map() {
	log_notice("dump node_map", 0);
	for (node_map::iterator it = this->_node_map.begin();
			it != this->_node_map.end(); it++) {
		log_notice("  node_map[%s] %d %d %d %d", it->first.c_str(), it->second.node_role,
				   it->second.node_state, it->second.node_balance, it->second.node_partition);
	}
	return;
}

void mock_cluster::dump_node_partition_map() {
	log_notice("dump node_partition_map", 0);
	for (node_partition_map::iterator it = this->_node_partition_map.begin();
			it != this->_node_partition_map.end(); it++) {
		log_notice("  master: %s", it->second.master.node_key.c_str());
		vector<partition_node> slave = it->second.slave;
		for (vector<partition_node>::iterator s_it = slave.begin();
			s_it != slave.end(); s_it++) {
			log_notice("  slave: %s", s_it->node_key.c_str());
		}
	}
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
cluster::partition_node mock_cluster::_get_partition_node(string server_name, int server_port, int balance) {
		partition_node pn;
		pn.node_key = this->to_node_key(server_name, server_port);
		pn.node_balance = balance;
		return pn;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
