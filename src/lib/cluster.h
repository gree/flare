/**
 *	cluster.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	CLUSTER_H
#define	CLUSTER_H

#include <fstream>
#include <map>
#include <stack>
#include <vector>

#include <boost/archive/xml_oarchive.hpp>
#include <boost/archive/xml_iarchive.hpp>
#include <boost/archive/archive_exception.hpp>
#include <boost/serialization/serialization.hpp>
#include <boost/serialization/nvp.hpp>
#include <boost/serialization/map.hpp>
#include <boost/serialization/string.hpp>
#include <boost/lexical_cast.hpp>

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

#include "connection.h"
#include "storage.h"
#include "thread_pool.h"
#include "key_resolver.h"
#include "coordinator.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

typedef class op_proxy_write op_proxy_write;
typedef class op_proxy_read op_proxy_read;

typedef class queue_proxy_read queue_proxy_read;
typedef shared_ptr<queue_proxy_read> shared_queue_proxy_read;

typedef class queue_proxy_write queue_proxy_write;
typedef shared_ptr<queue_proxy_write> shared_queue_proxy_write;

/**
 *	cluster class
 */
class cluster {
public:
	enum							type {
		type_index,
		type_node,
	};

	enum							replication {
		replication_async,
		replication_sync,
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
		state_ready,
	};

	enum							proxy_request {
		proxy_request_error_partition = -2,
		proxy_request_error_enqueue = -1,
		proxy_request_continue = 1,
		proxy_request_complete,
	};

	typedef struct		_index_server {
		string					index_server_name;
		int							index_server_port;
	} index_server;

	typedef struct		_node {
		string		node_server_name;
		int				node_server_port;
		role						node_role;
		state						node_state;
		int							node_partition;
		int							node_balance;
		int							node_thread_type;

		int parse(const char* p);

	private:
		friend class serialization::access;
		template<class T> void serialize(T& ar, const unsigned int node_map_version) {
			ar & BOOST_SERIALIZATION_NVP(node_server_name);
			ar & BOOST_SERIALIZATION_NVP(node_server_port);
			ar & BOOST_SERIALIZATION_NVP(node_role);
			ar & BOOST_SERIALIZATION_NVP(node_state);
			ar & BOOST_SERIALIZATION_NVP(node_partition);
			ar & BOOST_SERIALIZATION_NVP(node_balance);
			ar & BOOST_SERIALIZATION_NVP(node_thread_type);
		};
	} node;

	typedef struct		_partition_node {
		string					node_key;
		int							node_balance;
	} partition_node;

	typedef struct		_partition {
		partition_node					master;
		vector<partition_node>	slave;
		vector<string>					balance;
		vector<string>					prior_balance;
		map<string, bool>				index;
	} partition;

	typedef struct _node_shift_state {
		string node_key;
		state old_state;
		state new_state;
	} node_shift_state;

	typedef struct _node_shift_role {
		string node_key;
		role old_role;
		int old_partition;
		role new_role;
		int new_partition;
	} node_shift_role;
	
	typedef map<string, node>		node_map;
	typedef map<int, partition>	node_partition_map;

	static const int	default_thread_type = 16;
	static const int	default_partition_size = 1024;
	static const int	default_key_resolver_modular_virtual = 4096;

protected:
	thread_pool*					_thread_pool;
	storage::hash_algorithm _key_hash_algorithm;
	const storage::hash_algorithm _proxy_hash_algorithm;
	key_resolver*					_key_resolver;
	storage*							_storage;
	type									_type;
	pthread_mutex_t				_mutex_serialization;

	int										_master_reconstruction;
	pthread_mutex_t				_mutex_master_reconstruction;

	uint64_t							_node_map_version;
	pthread_mutex_t				_mutex_node_map_version;
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
	int										_monitor_read_timeout;
	int										_partition_size;
	int										_thread_type;
#ifdef ENABLE_MYSQL_REPLICATION
	bool									_mysql_replication;
#endif
	coordinator*					_coordinator;
	int										_noreply_window_limit;

	// [node]
	vector<index_server>	_index_servers;
	int										_proxy_concurrency;
	int										_reconstruction_interval;
	int										_reconstruction_bwlimit;
	replication						_replication_type;
	uint32_t							_proxy_prior_netmask;
	uint32_t							_max_total_thread_queue;

public:
	cluster(thread_pool* tp, string server_name, int server_port);
	virtual ~cluster();

	int startup_index(coordinator* coord, key_resolver::type key_resolver_type, int key_resolver_modular_hint, int key_resolver_modular_virtual);
	int startup_node(const vector<index_server>& index_servers, uint32_t proxy_prior_netmask);

	int add_node(string node_server_name, int node_server_port);
	int down_node(string node_server_name, int node_server_port, bool shutdown_mode = false);
	int shutdown_node(string node_server_name, int node_server_port);
	int ready_node(string node_server_name, int node_server_port);
	int up_node(string node_server_name, int node_server_port);
	int remove_node(string node_server_name, int node_server_port);
	int set_node_role(string node_server_name, int node_server_port, role node_role, int node_balance, int node_partition);
	int set_node_state(string node_server_name, int node_server_port, state node_state);
	int reconstruct_node(vector<node> v, uint64_t node_map_version = 0);

	int set_storage(storage* st) { this->_storage = st; return 0; };

	int notify_master_reconstruction() { int n; pthread_mutex_lock(&this->_mutex_master_reconstruction); this->_master_reconstruction--; n = this->_master_reconstruction; pthread_mutex_unlock(&this->_mutex_master_reconstruction); return n; };
	int activate_node(bool skip_ready_state = false);
	int deactivate_node();
	int shutdown_node();
	int request_down_node(string node_server_name, int node_server_port);
	int request_up_node(string node_server_name, int node_server_port);
	proxy_request pre_proxy_read(op_proxy_read* op, storage::entry& e, void* parameter, shared_queue_proxy_read& q);
	proxy_request pre_proxy_write(op_proxy_write* op, shared_queue_proxy_write& q, uint64_t generic_value = 0);
	proxy_request post_proxy_write(op_proxy_write* op, bool sync = false);

	uint64_t get_node_map_version() {
		uint64_t node_map_version;
		pthread_mutex_lock(&this->_mutex_node_map_version);
		node_map_version = this->_node_map_version;
		pthread_mutex_unlock(&this->_mutex_node_map_version);
		return node_map_version;
	}
	node get_node(string node_key);
	inline node get_node(string node_server_name, int node_server_port) {
		return this->get_node(this->to_node_key(node_server_name, node_server_port));
	}
	vector<node> get_node();
	vector<node> get_slave_node();

	storage::hash_algorithm get_key_hash_algorithm() { return this->_key_hash_algorithm; };
	storage::hash_algorithm get_proxy_hash_algorithm() { return this->_proxy_hash_algorithm; };
	int set_key_hash_algorithm(storage::hash_algorithm key_hash_algorithm) { this->_key_hash_algorithm = key_hash_algorithm; return 0; };
	key_resolver* get_key_resolver() { return this->_key_resolver; };
	int set_monitor_threshold(int monitor_threshold);
	int set_monitor_interval(int monitor_interval);
	int set_monitor_read_timeout(int monitor_read_timeout);
	int get_partition_size() { return this->_partition_size; };
	int set_partition_size(int partition_size) { this->_partition_size = partition_size; return 0; };
	int set_proxy_concurrency(int proxy_concurrency) { this->_proxy_concurrency = proxy_concurrency; return 0; };
	int get_reconstruction_interval() { return this->_reconstruction_interval; };
	int set_reconstruction_interval(int reconstruction_interval) { this->_reconstruction_interval = reconstruction_interval; return 0; };
	int get_reconstruction_bwlimit() { return this->_reconstruction_bwlimit; };
	int set_reconstruction_bwlimit(int reconstruction_bwlimit) { this->_reconstruction_bwlimit = reconstruction_bwlimit; return 0; };
	replication get_replication_type() { return this->_replication_type; };
	int set_replication_type(string replication_type) { cluster::replication_cast(replication_type, this->_replication_type); return 0; };
	string get_server_name() { return this->_server_name; };
	int get_server_port() { return this->_server_port; };
	string get_index_server_name() { return this->_index_servers[0].index_server_name; };
	int get_index_server_port() { return this->_index_servers[0].index_server_port; };
	int set_index_servers(const vector<index_server>& index_servers) {
		this->_index_servers = index_servers;
		return 0;
	};
	uint32_t get_max_total_thread_queue() { return this->_max_total_thread_queue; };
	uint32_t set_max_total_thread_queue(uint32_t max_total_thread_queue) { this->_max_total_thread_queue = max_total_thread_queue; return 0; };

#ifdef ENABLE_MYSQL_REPLICATION
	int set_mysql_replication(bool mysql_replication) { this->_mysql_replication = mysql_replication; return 0; };
	bool is_mysql_replication() { return this->_mysql_replication; };
#endif
	int set_noreply_window_limit(int noreply_window_limit) { this->_noreply_window_limit = noreply_window_limit; return 0; };
	int get_noreply_window_limit() { return this->_noreply_window_limit; }

	inline string to_node_key(string server_name, int server_port) {
		string node_key = server_name + ":" + lexical_cast<string>(server_port);
		return node_key;
	};

	inline int from_node_key(string node_key, string& server_name, int& server_port) {
		string::size_type n = node_key.find(":", 0);
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

	static inline int replication_cast(string s, replication& t) {
		if (s == "async") {
			t = replication_async;
		} else if (s == "sync") {
			t = replication_sync;
		} else {
			return -1;
		}
		return 0;
	}

	static inline string replication_cast(replication t) {
		switch (t) {
		case replication_async:
			return "async";
		case replication_sync:
			return "sync";
		}
		return "";
	}

	static inline int role_cast(string s, role& r) {
		if (s == "master") {
			r = role_master;
		} else if (s == "slave") {
			r = role_slave;
		} else if (s == "proxy") {
			r = role_proxy;
		} else {
			return -1;
		}
		return 0;
	}

	static inline string role_cast(role r) {
		switch (r) {
		case role_master:
			return "master";
		case role_slave:
			return "slave";
		case role_proxy:
			return "proxy";
		}
		return "";
	}

	static inline int state_cast(string s, state& t) {
		if (s == "active") {
			t = state_active;
		} else if (s == "prepare") {
			t = state_prepare;
		} else if (s == "down") {
			t = state_down;
		} else if (s == "ready") {
			t = state_ready;
		} else {
			return -1;
		}
		return 0;
	}

	static inline string state_cast(state t) {
		switch (t) {
		case state_active:
			return "active";
		case state_prepare:
			return "prepare";
		case state_down:
			return "down";
		case state_ready:
			return "ready";
		}
		return "";
	}

protected:
	int _shift_node_state(string node_key, state old_state, state new_state);
	int _shift_node_role(string node_key, role old_role, int old_partition, role new_role, int new_partition);
	int _enqueue(shared_thread_queue q, string node_key, int key_hash, bool sync = false);
	int _enqueue(shared_thread_queue q, thread_pool::thread_type t, bool sync);
	int _broadcast(shared_thread_queue q, bool sync, vector<string> prior_node_key, string exclude_node_key = "");
	int _save();
	int _load(bool update_monitor = true);
	void _update();
	int _reconstruct_node_partition(bool lock = true);
	int _check_node_balance(string node_key, int node_balance);
	int _check_node_partition(int node_partition, bool& preparing);
	int _check_node_partition_for_new(int node_partition, bool& preparing);
	int _determine_partition(storage::entry& e, partition& p, bool include_prepare, bool& is_preprare);
	string _get_partition_key(string key);
	int _get_proxy_thread(string node_key, int key_hash, shared_thread& t);
	shared_connection _open_index();
	shared_connection _open_index_single_server();
	shared_connection _open_index_redundant();
	int _get_reconstruction_bwlimit_for_new_partition(size_t current_partition_size);

	int _set_node_map_version(uint64_t node_map_version) {
		pthread_mutex_lock(&this->_mutex_node_map_version);
		this->_node_map_version = node_map_version;
		pthread_mutex_unlock(&this->_mutex_node_map_version);
		return 0;
	}

	uint64_t _increment_node_map_version() {
		uint64_t node_map_version;
		pthread_mutex_lock(&this->_mutex_node_map_version);
		node_map_version = this->_node_map_version;
		this->_node_map_version++;
		pthread_mutex_unlock(&this->_mutex_node_map_version);
		return node_map_version;
	}
};

}	// namespace flare
}	// namespace gree

#endif	// CLUSTER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
