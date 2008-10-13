/**
 *	cluster.cc
 *
 *	implementation of gree::flare::cluster
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "cluster.h"
#include "op_node_add.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for cluster
 */
cluster::cluster(thread_pool* tp, string server_name, int server_port):
		_thread_pool(tp),
		_server_name(server_name),
		_server_port(server_port),
		_thread_type_index(default_thread_type_index),
		_index_server_name(""),
		_index_server_port(0) {
	pthread_rwlock_init(&this->_mutex_node_map, NULL);
	pthread_rwlock_init(&this->_mutex_node_thread_type_map, NULL);
	pthread_rwlock_init(&this->_mutex_node_partition_map, NULL);
}

/**
 *	dtor for cluster
 */
cluster::~cluster() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	startup proc for index process
 */
int cluster::startup_index() {
	this->_type = type_index;

	return 0;
}

/**
 *	startup proc for node process
 */
int cluster::startup_node(string index_server_name, int index_server_port) {
	this->_type = type_node;
	this->_index_server_name = index_server_name;
	this->_index_server_port = index_server_port;

	log_notice("setting up cluster node... (type=%d, index_server_name=%s, index_server_port=%d)", this->_type, this->_index_server_name.c_str(), this->_index_server_port);

	shared_connection c(_new_ connection());
	if (c->open(this->_index_server_name, this->_index_server_port) < 0) {
		log_err("failed to connect to index server", 0);
		return -1;
	}

	op_node_add* p = _new_ op_node_add(c, this);
	if (p->run_client() < 0) {
		log_err("failed to add node to index server", 0);
		return -1;
	}
	
	// set state and other nodes

	return 0;
}

/**
 *	[index] add new node
 */
int cluster::add_node(string node_server_name, int node_server_port) {
	if (this->_type != type_index) {
		log_err("node add request for non-index server", 0);
		return -1;
	}

	string node_key = this->to_node_key(node_server_name, node_server_port);
	log_debug("adding new node (server_name=%s, server_port=%d, node_key=%s)", node_server_name.c_str(), node_server_port, node_key.c_str());

	// add node to map
	pthread_rwlock_wrlock(&this->_mutex_node_map);
	try {
		if (this->_node_map.count(node_key) > 0) {
			log_warning("node_key [%s] is already in node map", node_key.c_str());
			throw -1;
		}

		int thread_type_index;
		ATOMIC_ADD(&this->_thread_type_index, 1, thread_type_index); 

		node n;
		n.node_server_name = node_server_name;
		n.node_server_port = node_server_port;
		n.node_state = state_proxy;			// initial state should be "proxy"
		n.node_thread_type = thread_type_index;
		this->_node_map[node_key] = n;

		pthread_rwlock_wrlock(&this->_mutex_node_thread_type_map);
		this->_node_thread_type_map[node_key] = thread_type_index;
		pthread_rwlock_unlock(&this->_mutex_node_thread_type_map);
	
		log_debug("node [%s] added (state=%d, thread_type=%d)", node_key.c_str(), n.node_state, n.node_thread_type);
	} catch (int e) {
		pthread_rwlock_unlock(&this->_mutex_node_map);
		return e;
	}
	pthread_rwlock_unlock(&this->_mutex_node_map);

	// create monitoring thread
	
	// notify other nodes
	
	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
