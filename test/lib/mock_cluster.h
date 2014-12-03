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

	void set_node_map_version(uint64_t version) {
		this->_node_map_version = version;
	};

private:
	cluster::partition_node _get_partition_node(string server_name, int server_port, int balance);
};

}	// namespace flare
}	// namespace gree

#endif // MOCK_CLUSTER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
