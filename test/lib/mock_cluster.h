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
 *	mock_cluster.h
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 */
#ifndef MOCK_CLUSTER_H
#define MOCK_CLUSTER_H

#include <string>

#include "cluster.h"
#include "key_resolver_modular.h"

namespace gree {
namespace flare {

struct mock_cluster : public cluster {
private:
	using cluster::_node_key;
	using cluster::_node_map;
	using cluster::_node_partition_map;

public:
	mock_cluster(string server_name, int server_port);
	virtual ~mock_cluster();

	/*
	 * set partition to node_partition_map
	 */
	cluster::partition set_partition(int partition, node master, node slave[] = NULL, int slave_num = 0);
	/*
	 * set node to node_map
	 */
	cluster::node set_node(string server_name, int server_port, role r, state s, int partition = 0, int balance = 0);
	void clear_node_map();
	void clear_node_partition_map();
	void dump_node_map();
	void dump_node_partition_map();

private:
	cluster::partition_node _get_partition_node(string server_name, int server_port, int balance);
};

}	// namespace flare
}	// namespace gree

#endif // MOCK_CLUSTER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
