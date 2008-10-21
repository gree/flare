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
#include <fstream>

#include <boost/archive/text_oarchive.hpp>
#include <boost/archive/text_iarchive.hpp>
#include <boost/serialization/map.hpp>
#include <boost/serialization/string.hpp>
#include <boost/lexical_cast.hpp>

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

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

	enum							role {
		role_master,
		role_slave,
		role_proxy,
	};

	enum							state {
		state_active,
		state_prepare,
		state_down,
	};

	typedef struct		_node {
		string					node_server_name;
		int							node_server_port;
		role						node_role;
		state						node_state;
		int							node_partition;
		int							node_balance;
		int							node_thread_type;

		int parse(const char* p);

	private:
		friend class serialization::access;
		template<class T> void serialize(T& ar, uint32_t version) {
			ar & node_server_name;
			ar & node_server_port;
			ar & node_role;
			ar & node_state;
			ar & node_partition;
			ar & node_balance;
			ar & node_thread_type;
		};
	} node;

	typedef struct		_partition_node {
		string					node_key;
		int							node_balance;
	} partition_node;

	typedef struct		_partition {
		partition_node					master;
		vector<partition_node>	slave;
	} partition;
	
	typedef map<string, node>		node_map;
	typedef map<int, partition>	node_partition_map;

	static const int	default_thread_type = 16;

protected:
	thread_pool*					_thread_pool;
	type									_type;
	string								_data_dir;
	pthread_mutex_t				_mutex_serialization;

	node_map							_node_map;
	node_partition_map		_node_partition_map;
	node_partition_map		_node_partition_prepare_map;
	pthread_rwlock_t			_mutex_node_map;
	pthread_rwlock_t			_mutex_node_partition_map;

	string								_node_key;
	string								_server_name;
	int										_server_port;

	// [index]
	int										_monitor_threshold;
	int										_monitor_interval;
	int										_thread_type;

	// [node]
	string								_index_server_name;
	int										_index_server_port;

public:
	cluster(thread_pool* tp, string data_dir, string server_name, int server_port);
	virtual ~cluster();

	int startup_index();
	int startup_node(string index_server_name, int index_server_port);
	int reconstruct_node(vector<node> v);

	int add_node(string node_server_name, int node_server_port);
	int down_node(string node_server_name, int node_server_port);
	int up_node(string node_server_name, int node_server_port);

	inline node get_node(string node_key) {
		node n;
		pthread_rwlock_rdlock(&this->_mutex_node_map);
		if (this->_node_map.count(node_key) > 0) {
			n = this->_node_map[node_key];
		} else {
			n.node_server_name = "";
			n.node_server_port = 0;
		}
		pthread_rwlock_unlock(&this->_mutex_node_map);

		return n;
	};
	inline node get_node(string node_server_name, int node_server_port) {
		return this->get_node(this->to_node_key(node_server_name, node_server_port));
	}
	vector<node> get_node();

	int set_monitor_threshold(int monitor_threshold);
	int set_monitor_interval(int monitor_interval);
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

protected:
	int _broadcast(shared_thread_queue q, bool sync = false);
	int _save();
	int _load();
	int _reconstruct_node_partition(bool lock = true);
};

}	// namespace flare
}	// namespace gree

#endif	// __CLUSTER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
