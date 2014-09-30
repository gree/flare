/**
 *	mock_cluster.h
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 */
#ifndef MOCK_CLUSTER_H
#define MOCK_CLUSTER_H

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
	mock_cluster(string server_name, int server_port):
			cluster(NULL, server_name, server_port) {
		this->_key_hash_algorithm = storage::hash_algorithm_simple;
		this->_key_resolver = new key_resolver_modular(1024, 1, 4096);
	};

	~mock_cluster() {
	};

	cluster::node set_node(string server_name, int server_port, cluster::role r, cluster::state s, int partition = 0, int balance = 0) {
		string node_key = this->to_node_key(server_name, server_port);
		if (this->_node_map.count(node_key) > 0) {
			this->_node_map[node_key].node_role = r;
			this->_node_map[node_key].node_state = s;
			this->_node_map[node_key].node_partition = partition;
			return this->_node_map[node_key];
		} else {
			cluster::node n;
			n.node_server_name = server_name;
			n.node_server_port = server_port;
			n.node_role = r;
			n.node_state = s;
			if (r == cluster::role_proxy) {
				n.node_partition = -1;
			} else {
				n.node_partition = partition;
			}
			n.node_balance = balance;
			n.node_thread_type = this->_thread_type;
			this->_thread_type++;
			this->_node_map[node_key] = n;
			return n;
		}
	};
};

}	// namespace flare
}	// namespace gree

#endif // MOCK_CLUSTER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
