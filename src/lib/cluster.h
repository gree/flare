/**
 *	cluster.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__CLUSTER_H__
#define	__CLUSTER_H__

#include <map>
#include <vector>

#include <boost/lexical_cast.hpp>

#include "connection.h"
#include "thread_pool.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	cluster class
 */
class cluster {
public:
	enum							type {
		type_index,
		type_node,
	};

	enum							state {
		state_master,
		state_slave,
		state_proxy,
	};

	typedef struct		_node {
		string					node_server_name;
		int							node_server_port;
		state						node_state;
		int							node_thread_type;
	} node;

	typedef struct		_partition {
		string					master;
		vector<string>	slave;
	} partition;
	
	typedef map<string, node>		node_map;
	typedef map<string, int>		node_thread_type_map;
	typedef map<int, partition>	node_partition_map;

	static const int	default_thread_type_index = 16;

protected:
	thread_pool*			_thread_pool;
	type							_type;
	state							_state;
	string						_server_name;
	int								_server_port;
	int								_thread_type_index;

	node_map							_node_map;
	node_thread_type_map	_node_thread_type_map;
	node_partition_map		_node_partition_map;
	pthread_rwlock_t			_mutex_node_map;
	pthread_rwlock_t			_mutex_node_thread_type_map;
	pthread_rwlock_t			_mutex_node_partition_map;

	// map

	// node
	string						_index_server_name;
	int								_index_server_port;

public:
	cluster(thread_pool* tp, string server_name, int server_port);
	virtual ~cluster();

	int startup_index();
	int startup_node(string index_server_name, int index_server_port);

	int add_node(string node_server_name, int node_server_port);

	string get_server_name() { return this->_server_name; };
	int get_server_port() { return this->_server_port; };
	string get_index_server_name() { return this->_index_server_name; };
	int get_index_server_port() { return this->_index_server_port; };

	inline string to_node_key(string server_name, int server_port) {
		string node_key = server_name + ":" + lexical_cast<string>(server_port);
		return node_key;
	};

	inline int from_node_key(string node_key, string& server_name, int& server_port) {
		uint32_t n = node_key.find(":", 0);
		if (n == string::npos) {
			return -1;
		}
		server_name = node_key.substr(0, n);
		try {
			server_port = lexical_cast<int>(node_key.substr(n+1));
		} catch (bad_lexical_cast e) {
			return -1;
		}
		return 0;
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __CLUSTER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
