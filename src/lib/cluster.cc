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
#include "connection_tcp.h"
#include "handler_monitor.h"
#include "handler_proxy.h"
#include "handler_reconstruction.h"
#include "key_resolver_modular.h"
#include "op_meta.h"
#include "op_node_add.h"
#include "op_node_role.h"
#include "op_node_state.h"
#include "op_shutdown.h"
#include "op_proxy_read.h"
#include "op_proxy_write.h"
#include "queue_node_sync.h"
#include "queue_node_state.h"
#include "queue_proxy_read.h"
#include "queue_proxy_write.h"
#include "queue_update_monitor_option.h"
#include "coordinator.h"

#include <functional>
#include <boost/bind.hpp>

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
		_key_hash_algorithm(storage::hash_algorithm_simple),
		_proxy_hash_algorithm(storage::hash_algorithm_murmur),
		_key_resolver(NULL),
		_storage(NULL),
		_master_reconstruction(0),
		_node_map_version(0),
		_server_name(server_name),
		_server_port(server_port),
		_monitor_threshold(0),
		_monitor_interval(0),
		_monitor_read_timeout(0),
		_partition_size(default_partition_size),
		_thread_type(default_thread_type),
#ifdef ENABLE_MYSQL_REPLICATION
		_mysql_replication(false),
#endif
		_coordinator(NULL),
		_noreply_window_limit(0),
		_proxy_concurrency(0),
		_reconstruction_interval(0),
		_reconstruction_bwlimit(0),
		_proxy_prior_netmask(0), 
		_max_total_thread_queue(0) {
	this->_node_key = this->to_node_key(server_name, server_port);
	pthread_mutex_init(&this->_mutex_serialization, NULL);
	pthread_mutex_init(&this->_mutex_master_reconstruction, NULL);
	pthread_mutex_init(&this->_mutex_node_map_version, NULL);
	pthread_rwlock_init(&this->_mutex_node_map, NULL);
	pthread_rwlock_init(&this->_mutex_node_partition_map, NULL);
}

/**
 *	dtor for cluster
 */
cluster::~cluster() {
	if (this->_coordinator != NULL) {
		this->_coordinator->set_update_handler(NULL);
		this->_coordinator = NULL;
	}

	delete this->_key_resolver;
	this->_key_resolver = NULL;
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	parse node sync line
 */
int cluster::node::parse(const char* p) {
	char q[BUFSIZ];
	try {
		int i = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "NODE") != 0) {
			log_warning("unknown first token [%s]", q);
			return -1;
		}

		// node_server_name
		i += util::next_word(p+i, q, sizeof(q));
		if (q[0] == '\0') {
			log_warning("no server name (required)", 0);
			return -1;
		}
		this->node_server_name = q;

		// node_server_port
		i += util::next_digit(p+i, q, sizeof(q));
		if (q[0] == '\0') {
			log_warning("no server port (required)", 0);
			return -1;
		}
		this->node_server_port = lexical_cast<int>(q);

		// node_role
		i += util::next_digit(p+i, q, sizeof(q));
		if (q[0] == '\0') {
			log_warning("no role (required)", 0);
			return -1;
		}
		this->node_role = static_cast<cluster::role>(lexical_cast<int>(q));

		// node_state
		i += util::next_digit(p+i, q, sizeof(q));
		if (q[0] == '\0') {
			log_warning("no state (required)", 0);
			return -1;
		}
		this->node_state = static_cast<cluster::state>(lexical_cast<int>(q));

		// node_partition
		i += util::next_digit(p+i, q, sizeof(q));
		if (q[0] == '\0') {
			log_warning("no partition (required)", 0);
			return -1;
		}
		this->node_partition = lexical_cast<int>(q);

		// node_balance
		i += util::next_digit(p+i, q, sizeof(q));
		if (q[0] == '\0') {
			log_warning("no balance (required)", 0);
			return -1;
		}
		this->node_balance = lexical_cast<int>(q);

		// node_thread_type
		i += util::next_digit(p+i, q, sizeof(q));
		if (q[0] == '\0') {
			log_warning("no thread_type (required)", 0);
			return -1;
		}
		this->node_thread_type = lexical_cast<int>(q);
	} catch (bad_lexical_cast e) {
		log_warning("invalid digit [%s]", e.what());
		return -1;
	}

	return 0;
}

/**
 *	startup proc for index process
 */
int cluster::startup_index(coordinator* coord, key_resolver::type key_resolver_type, int key_resolver_modular_hint, int key_resolver_modular_virtual) {
	this->_type = type_index;

	// setup
	if (coord == NULL) {
		log_err("invalid coordinator %p", coord);
		return -1;
	}
	this->_coordinator = coord;

	// key resolver
	if (key_resolver_type == key_resolver::type_modular) {
		this->_key_resolver = new key_resolver_modular(this->_partition_size, key_resolver_modular_hint, key_resolver_modular_virtual);
	} else {
		log_err("unknown key resolver type [%s]", key_resolver::type_cast(key_resolver_type).c_str());
		return -1;
	}
	if (this->_key_resolver->startup() < 0) {
		return -1;
	}

	// load
	coordinator::shared_operation operation;
	if (this->_coordinator->begin_operation(operation, "startup index") < 0) {
		log_err("failed to acquire coordination lock", 0);
		return -1;
	}
	if (this->_load(false) < 0) {
		log_err("failed to load serialized vars (node map, etc)", 0);
		this->_coordinator->end_operation(operation);
		return -1;
	}
	if (this->_reconstruct_node_partition() < 0) {
		log_err("failed to reconstruct node partition map", 0);
		this->_coordinator->end_operation(operation);
		return -1;
	}
	if (this->_coordinator->end_operation(operation) < 0) {
		log_err("failed to release coordination lock", 0);
		return -1;
	}

	// monitoring threads
	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		shared_thread t = this->_thread_pool->get(it->second.node_thread_type);
		handler_monitor* h = new handler_monitor(t, this, it->second.node_server_name, it->second.node_server_port);
		h->set_monitor_threshold(this->_monitor_threshold);
		h->set_monitor_interval(this->_monitor_interval);
		h->set_monitor_read_timeout(this->_monitor_read_timeout);
		t->trigger(h);
	}

	this->_coordinator->set_update_handler(bind(&cluster::_update, this));

	return 0;
}

/**
 *	startup proc for node process
 */
int cluster::startup_node(const vector<index_server>& index_servers, uint32_t proxy_prior_netmask) {
	this->_type = type_node;
	this->_index_servers = index_servers;

	if (proxy_prior_netmask != 0) {
		this->_proxy_prior_netmask = htonl((uint32_t)0xffffffff << (32-proxy_prior_netmask)); // length -> mask bits
		struct in_addr in;
		in.s_addr = util::inet_addr(this->_server_name.c_str(), this->_proxy_prior_netmask);
		log_notice("my network address (server_name=%s, proxy_prior_netmask=0x%x, prior_network_address=%s)", this->_server_name.c_str(), ntohl(this->_proxy_prior_netmask), inet_ntoa(in));
	}

	log_notice("setting up cluster node... (type=%d, index_server_name=%s, index_server_port=%d)", this->_type, this->_index_servers[0].index_server_name.c_str(), this->_index_servers[0].index_server_port);

	shared_connection c = this->_open_index();
	if (!c) {
		log_err("failed to connect to index server", 0);
		return -1;
	}

	op_node_add* p_na = new op_node_add(c, this);
	vector<node> v;
	if (p_na->run_client(v) < 0) {
		log_err("failed to add node to index server", 0);
		delete p_na;
		return -1;
	}
	delete p_na;

	// get meta data from index server
	key_resolver::type key_resolver_type;
	int partition_size = cluster::default_partition_size;
	storage::hash_algorithm key_hash_algorithm = storage::hash_algorithm_simple;
	int key_resolver_modular_hint = 0;
	int key_resolver_modular_virtual = cluster::default_key_resolver_modular_virtual;
	op_meta* p_m = new op_meta(c, this);
	if (p_m->run_client(partition_size, key_hash_algorithm, key_resolver_type, key_resolver_modular_hint, key_resolver_modular_virtual) < 0) {
		log_err("failed to get meta data from index server", 0);
		delete p_m;
		return -1;
	}
	delete p_m;

	log_notice("meta data from index server:", 0);
	log_notice("  partition_size:                 %d", partition_size);
	log_notice("  key_hash_algorithm:             %s", storage::hash_algorithm_cast(key_hash_algorithm).c_str());
	log_notice("  key_resolver_type:              %s", key_resolver::type_cast(key_resolver_type).c_str());
	log_notice("  key_resolver_modular_hint:      %d", key_resolver_modular_hint);
	log_notice("  key_resolver_modular_virtual:   %d", key_resolver_modular_virtual);
	this->_partition_size = partition_size;
	this->_key_hash_algorithm = key_hash_algorithm;

	// startup key resolver
	if (key_resolver_type == key_resolver::type_modular) {
		this->_key_resolver = new key_resolver_modular(partition_size, key_resolver_modular_hint, key_resolver_modular_virtual);
	} else {
		log_err("unknown key resolver type [%s]", key_resolver::type_cast(key_resolver_type).c_str());
		return -1;
	}
	if (this->_key_resolver->startup() < 0) {
		return -1;
	}

	// set state and other nodes
	if (this->reconstruct_node(v) < 0) {
		log_err("failed to reconstruct node map", 0);
		return -1;
	}

	return 0;
}

/**
 *	get node info vector
 */
vector<cluster::node> cluster::get_node() {
	vector<node> v;

	pthread_rwlock_rdlock(&this->_mutex_node_map);
	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		v.push_back(it->second);
	}
	pthread_rwlock_unlock(&this->_mutex_node_map);

	return v;
}

cluster::node cluster::get_node(string node_key) {
	node n;
	n.node_server_name = "";
	n.node_server_port = 0;
	n.node_role = role_proxy;
	n.node_state = state_down;
	n.node_partition = -1;
	n.node_balance = 0;
	n.node_thread_type = 0;

	pthread_rwlock_rdlock(&this->_mutex_node_map);
	if (this->_node_map.count(node_key) > 0) {
		n = this->_node_map[node_key];
	}
	pthread_rwlock_unlock(&this->_mutex_node_map);

	return n;
};

/**
 *	get slave node info vector
 */
vector<cluster::node> cluster::get_slave_node() {
	vector<node> v;

	node n = this->get_node(this->_node_key);
	if (n.node_role != role_master) {
		return v;
	}

	pthread_rwlock_rdlock(&this->_mutex_node_partition_map);
	vector<partition_node> slave;
	if (this->_node_partition_map.count(n.node_partition) > 0) {
		slave = this->_node_partition_map[n.node_partition].slave;
	} else if (this->_node_partition_prepare_map.count(n.node_partition) > 0) {
		slave = this->_node_partition_prepare_map[n.node_partition].slave;
	} else {
		// something is going wrong
		log_warning("not found node_partition [%d]", n.node_partition);
	}
	pthread_rwlock_unlock(&this->_mutex_node_partition_map);

	for (vector<partition_node>::iterator it = slave.begin(); it != slave.end(); it++) {
		node tmp = this->get_node(it->node_key);
		v.push_back(tmp);
	}

	return v;
}

/**
 *	[index] add new node
 */
int cluster::add_node(string node_server_name, int node_server_port) {
	if (this->_type != type_index) {
		log_err("node add request for non-index server", 0);
		return -1;
	}

	coordinator::shared_operation operation;
	ostringstream msg;
	msg << "add node " << node_server_name << ":" << node_server_port;
	if (this->_coordinator->begin_operation(operation, msg.str()) < 0) {
		log_err("failed to begin operation for %s:%d", node_server_name.c_str(), node_server_port);
		return -1;
	}

	string node_key = this->to_node_key(node_server_name, node_server_port);
	log_debug("adding new node (server_name=%s, server_port=%d, node_key=%s)", node_server_name.c_str(), node_server_port, node_key.c_str());

	// add node to map
	int thread_type;
	bool replace = false;
	pthread_rwlock_wrlock(&this->_mutex_node_map);
	try {
		if (this->_load() < 0) {
			log_warning("failed to load nodemap", 0);
			throw -1;
		}
		
		if (this->_node_map.count(node_key) > 0) {
			if (this->_node_map[node_key].node_state == state_down) {
				log_notice("node_key [%s] is already in node map (state is down -> continue processing)", node_key.c_str());
				thread_type = this->_node_map[node_key].node_thread_type;
				replace = true;
			} else {
				log_warning("node_key [%s] is already in node map", node_key.c_str());
				throw -1;
			}
		} else {
			thread_type = this->_thread_type;
			this->_thread_type++;
		}

		if (replace == false) {
			// initial node setup
			node n;
			n.node_server_name = node_server_name;
			n.node_server_port = node_server_port;
			n.node_role = role_proxy;
			n.node_state = state_active;
			n.node_partition = -1;
			n.node_balance = 0;
			n.node_thread_type = thread_type;
			this->_node_map[node_key] = n;
			log_debug("node is [%s] added to node map (state=%d, thread_type=%d)", node_key.c_str(), n.node_state, n.node_thread_type, replace);
		} else {
			log_debug("node is already in node map (perhaps node is restarting) (state=%d, thread_type=%d)", this->_node_map[node_key].node_state, this->_node_map[node_key].node_thread_type);
		}

		if (this->_save() < 0) {
			log_err("failed to save nodemap and skip broadcasting", 0);
			throw -1;
		}
	} catch (int e) {
		pthread_rwlock_unlock(&this->_mutex_node_map);
		this->_coordinator->end_operation(operation);
		return e;
	}
	pthread_rwlock_unlock(&this->_mutex_node_map);

	// create monitoring thread
	if (replace == false) {
		shared_thread t = this->_thread_pool->get(thread_type);
		handler_monitor* h = new handler_monitor(t, this, node_server_name, node_server_port);
		h->set_monitor_threshold(this->_monitor_threshold);
		h->set_monitor_interval(this->_monitor_interval);
		h->set_monitor_read_timeout(this->_monitor_read_timeout);
		t->trigger(h);
	}

	// notify other nodes - add node
	shared_queue_node_sync q(new queue_node_sync(this));
	vector<string> dummy;
	this->_broadcast(q, false, dummy);
	
	this->_coordinator->end_operation(operation);
	return 0;
}

/**
 *	[index] node down event handler
 */
int cluster::down_node(string node_server_name, int node_server_port, bool shutdown_mode) {
	string node_key = this->to_node_key(node_server_name, node_server_port);
	string exclude_node_key;

	coordinator::shared_operation operation;
	ostringstream msg;
	msg << "down node " << node_key << " shutdown_mode=" << shutdown_mode;
	if (this->_coordinator->begin_operation(operation, msg.str()) < 0) {
		log_err("failed to begin operation for %s", node_key.c_str());
		return -1;
	}

	if (shutdown_mode) {
		exclude_node_key = node_key; // skip broadcasting to a terminated node.
	} else {
		log_notice("handling node down event [node_key=%s]", node_key.c_str());
		exclude_node_key = "";
	}

	pthread_rwlock_wrlock(&this->_mutex_node_map);
	pthread_rwlock_wrlock(&this->_mutex_node_partition_map);
	vector<string> prior_node_key;
	try {
		if (this->_load() < 0) {
			log_warning("failed to load nodemap", 0);
			throw -1;
		}

		if (this->_node_map.count(node_key) == 0) {
			log_warning("no such node (node_key=%s)", node_key.c_str());
			throw -1;
		}
		if (this->_node_map[node_key].node_state == state_down) {
			log_notice("node is already down (node_key=%s)", node_key.c_str());
			throw 0;
		}

		node& n = this->_node_map[node_key];
		bool preserve = false;
		if (n.node_role == role_master) {
			if (n.node_state == state_active) {
				log_err("master node down -> finding an active slave and shift its role to master", 0);
				if (shutdown_mode) {
					log_err("master node[%s] maybe send shutdown op", node_key.c_str());
					exclude_node_key = "";	// try to send down message, and shift role master -> proxy.
				}
				if (this->_node_partition_map[n.node_partition].slave.size() == 0) {
					log_err("no slave for this partition (partition=%d) -> all requests for this partition will fail!", n.node_partition);
					preserve = true;		// leave role as master to keep partition count (*important*)
				} else {
					string failover_node_key = "";
					int balance = 0;
					int prev_balance = 0;
					for (vector<partition_node>::iterator it = this->_node_partition_map[n.node_partition].slave.begin(); it != this->_node_partition_map[n.node_partition].slave.end(); it++) {
						if (this->_node_map[it->node_key].node_state == state_active) {
							if (failover_node_key.empty() || it->node_balance > prev_balance) {	// first slave(balance == 0) or balance is largest.
								failover_node_key = it->node_key;
								prev_balance = it->node_balance;
							}
						}
						balance += it->node_balance;
					}

					if (failover_node_key.empty()) {
						log_err("no active slave :( -> all requests for this partition will fail!", 0);
						preserve = true;		// leave role as master to keep partition count (*important*)
					} else {
						// shift target slave role to master
						this->_node_map[failover_node_key].node_role = role_master;
						if (balance == 0) {
							this->_node_map[failover_node_key].node_balance++;
						}
						log_notice("found new master node (node_key=%s, partition=%d, balance=%d)", failover_node_key.c_str(), n.node_partition, this->_node_map[failover_node_key].node_balance);
						prior_node_key.push_back(failover_node_key);
					}
				}
			} else if (n.node_state == state_prepare || n.node_state == state_ready) {
				log_err("master node (prepare|ready) down -> clearing all preparing nodes in this partition (partition=%d)", n.node_partition);

				for (vector<partition_node>::iterator it = this->_node_partition_prepare_map[n.node_partition].slave.begin(); it != this->_node_partition_prepare_map[n.node_partition].slave.end(); it++) {
					log_debug("  -> node_key: %s", it->node_key.c_str());
					this->_node_map[it->node_key].node_role = role_proxy;
					this->_node_map[it->node_key].node_state = state_active;
					this->_node_map[it->node_key].node_balance = 0;
					this->_node_map[it->node_key].node_partition = -1;
				}
			}
		}

		log_notice("setting node state to down (and clearing role, etc)", 0);
		n.node_state = state_down;
		if (preserve == false) {
			n.node_role = role_proxy;
			n.node_partition = -1;
			n.node_balance = 0;
		}

		this->_reconstruct_node_partition(false);
		if (this->_save() < 0) {
			log_err("failed to save nodemap and skip broadcasting", 0);
			throw -1;
		}
	} catch (int e) {
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		pthread_rwlock_unlock(&this->_mutex_node_map);
		this->_coordinator->end_operation(operation);
		return e;
	}
	pthread_rwlock_unlock(&this->_mutex_node_partition_map);
	pthread_rwlock_unlock(&this->_mutex_node_map);

	// notify - down node
	shared_queue_node_sync q(new queue_node_sync(this));
	this->_broadcast(q, false, prior_node_key, exclude_node_key);

	this->_coordinator->end_operation(operation);
	return 0;
}

/**
 *	[index] node shutdown event handler
 */
int cluster::shutdown_node(string node_server_name, int node_server_port) {
	string node_key = this->to_node_key(node_server_name, node_server_port);
	log_notice("node shutdown event [node_key=%s]", node_key.c_str());
	return this->down_node(node_server_name, node_server_port, true);
}

/**
 *	[index] node ready event handler
 */
int cluster::ready_node(string node_server_name, int node_server_port) {
	string node_key = this->to_node_key(node_server_name, node_server_port);

	log_notice("handling node ready event [node_key=%s]", node_key.c_str());

	coordinator::shared_operation operation;
	ostringstream msg;
	msg << "ready node " << node_key;
	if (this->_coordinator->begin_operation(operation, msg.str()) < 0) {
		log_err("failed to begin operation for %s:%d", node_server_name.c_str(), node_server_port);
		return -1;
	}

	pthread_rwlock_wrlock(&this->_mutex_node_map);
	pthread_rwlock_wrlock(&this->_mutex_node_partition_map);
	try {
		if (this->_load() < 0) {
			log_warning("failed to load nodemap", 0);
			throw -1;
		}
		
		if (this->_node_map.count(node_key) == 0) {
			log_warning("no such node (node_key=%s)", node_key.c_str());
			throw -1;
		}
		node& n = this->_node_map[node_key];
		if (n.node_state != state_prepare) {
			log_notice("node state is not prepare (node_key=%s, node_state=%s)", node_key.c_str(), cluster::state_cast(n.node_state).c_str());
			throw -1;
		}

		this->_node_map[node_key].node_state = state_ready;

		this->_reconstruct_node_partition(false);
		if (this->_save() < 0) {
			log_err("failed to save nodemap and skip broadcasting", 0);
			throw -1;
		}
	} catch (int e) {
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		pthread_rwlock_unlock(&this->_mutex_node_map);
		this->_coordinator->end_operation(operation);
		return e;
	}
	pthread_rwlock_unlock(&this->_mutex_node_partition_map);
	pthread_rwlock_unlock(&this->_mutex_node_map);

	// notify - ready node
	shared_queue_node_sync q(new queue_node_sync(this));
	vector<string> dummy;
	this->_broadcast(q, false, dummy);

	this->_coordinator->end_operation(operation);
	return 0;
}

/**
 *	[index] node up event handler
 */
int cluster::up_node(string node_server_name, int node_server_port) {
	string node_key = this->to_node_key(node_server_name, node_server_port);

	log_notice("handling node up event [node_key=%s]", node_key.c_str());

	coordinator::shared_operation operation;
	ostringstream msg;
	msg << "up node " << node_key;
	if (this->_coordinator->begin_operation(operation, msg.str()) < 0) {
		log_err("failed to begin operation for %s:%d", node_server_name.c_str(), node_server_port);
		return -1;
	}

	pthread_rwlock_wrlock(&this->_mutex_node_map);
	pthread_rwlock_wrlock(&this->_mutex_node_partition_map);
	vector<string> prior_node_key;
	try {
		if (this->_load() < 0) {
			log_warning("failed to load nodemap", 0);
			throw -1;
		}

		if (this->_node_map.count(node_key) == 0) {
			log_warning("no such node (node_key=%s)", node_key.c_str());
			throw -1;
		}
		node& n = this->_node_map[node_key];
		if (n.node_state == state_active) {
			log_notice("node is already active (node_key=%s, node_state=%s)", node_key.c_str(), cluster::state_cast(n.node_state).c_str());
			throw 0;
		} else if (n.node_role != role_slave && n.node_state == state_prepare) {
			log_notice("node is not ready to be active (current state=prepare), skip this operation (node_key=%s, node_state=%s)", node_key.c_str(), cluster::state_cast(n.node_state).c_str());
			throw -1;
		}

		if (n.node_state == state_ready || (n.node_role == role_slave && n.node_state == state_prepare)) {
			// just shift state to active
			if (n.node_state == state_ready && n.node_role == role_master) {
				// when new master shifts from ready to active, we need to activate new master prior to other nodes (to avoid dead lock between nodes)
				prior_node_key.push_back(node_key);
				for (vector<partition_node>::iterator it = this->_node_partition_prepare_map[n.node_partition].slave.begin(); it != this->_node_partition_prepare_map[n.node_partition].slave.end(); it++) {
					prior_node_key.push_back(it->node_key);
				}
			}
		} else {
			if (n.node_role == role_master) {
				for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
					if (it->first == node_key) {
						continue;
					}
					if (it->second.node_partition == n.node_partition && it->second.node_state != state_down) {
						log_warning("preserved master node is up, but already have another master -> role is set to proxy (node_key=%s, node_partition=%d, node_state=%s)", it->first.c_str(), it->second.node_partition, cluster::state_cast(it->second.node_state).c_str());
						n.node_role = role_proxy;
						n.node_partition = -1;
						n.node_balance = 0;
					}
				}
			} else {
				log_notice("node role is set to proxy for safety...", 0);
				n.node_role = role_proxy;
				n.node_partition = -1;
			}
		}
		this->_node_map[node_key].node_state = state_active;

		this->_reconstruct_node_partition(false);
		if (this->_save() < 0) {
			log_err("failed to save nodemap and skip broadcasting", 0);
			throw -1;
		}
	} catch (int e) {
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		pthread_rwlock_unlock(&this->_mutex_node_map);
		this->_coordinator->end_operation(operation);
		return e;
	}
	pthread_rwlock_unlock(&this->_mutex_node_partition_map);
	pthread_rwlock_unlock(&this->_mutex_node_map);

	// notify - up node
	shared_queue_node_sync q(new queue_node_sync(this));
	this->_broadcast(q, false, prior_node_key);

	this->_coordinator->end_operation(operation);
	return 0;
}

/**
 *	[index] remove node from map
 *
 *	removing node is only available when node is down and not preserved
 */
int cluster::remove_node(string node_server_name, int node_server_port) {
	string node_key = this->to_node_key(node_server_name, node_server_port);

	log_notice("removing node [node_key=%s]", node_key.c_str());

	coordinator::shared_operation operation;
	ostringstream msg;
	msg << "remove node " << node_key;
	if (this->_coordinator->begin_operation(operation, msg.str()) < 0) {
		log_err("failed to begin operation for %s:%d", node_server_name.c_str(), node_server_port);
		return -1;
	}

	pthread_rwlock_wrlock(&this->_mutex_node_map);
	pthread_rwlock_wrlock(&this->_mutex_node_partition_map);
	try {
		if (this->_load() < 0) {
			log_warning("failed to load nodemap", 0);
			throw -1;
		}

		if (this->_node_map.count(node_key) == 0) {
			log_warning("no such node (node_key=%s)", node_key.c_str());
			throw -1;
		}

		node& n = this->_node_map[node_key];

		// see if node is really down and removable
		if (n.node_state != state_down) {
			log_warning("cannot remove active or preparing node (node_key=%s, node_stae=%s, node_role=%s)", node_key.c_str(), cluster::state_cast(n.node_state).c_str(), cluster::role_cast(n.node_role).c_str());
			throw -1;
		}
		bool need_preserving = true;
		if (n.node_role == role_master) {
			for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
				if (it->first == node_key) {
					continue;
				}
				if (it->second.node_partition == n.node_partition && it->second.node_state != state_down) {
					need_preserving = false;
					break;
				}
			}
			if (need_preserving) {
				log_warning("cannot remove preserved node (node_key=%s, node_stae=%s, node_role=%s)", node_key.c_str(), cluster::state_cast(n.node_state).c_str(), cluster::role_cast(n.node_role).c_str());
				throw -1;
			}
		}

		// remove a node
		thread_pool::local_map m = this->_thread_pool->get_active(n.node_thread_type);
		for (thread_pool::local_map::iterator it = m.begin(); it != m.end(); it++) {
			log_notice("killing monitoring thread(s)... (node_thread_type=%d, thread_id=%d)", n.node_thread_type, it->second->get_id());
			it->second->set_state("killed");
			it->second->shutdown(true, false);
		}
		this->_node_map.erase(node_key);

		this->_reconstruct_node_partition(false);
		if (this->_save() < 0) {
			log_err("failed to save nodemap and skip broadcasting", 0);
			throw -1;
		}
	} catch (int e) {
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		pthread_rwlock_unlock(&this->_mutex_node_map);
		this->_coordinator->end_operation(operation);
		return e;
	}

	pthread_rwlock_unlock(&this->_mutex_node_partition_map);
	pthread_rwlock_unlock(&this->_mutex_node_map);

	// notify - remove node
	shared_queue_node_sync q(new queue_node_sync(this));
	vector<string> dummy;
	this->_broadcast(q, false, dummy);

	this->_coordinator->end_operation(operation);
	return 0;
}

/**
 *	[index] set node role
 *
 *	node_partition is (currently) only available in case of [role=proxy, state=active] -> [role=master|slave]
 *	
 *	@todo	too long, too complicated -> refactoring
 */
int cluster::set_node_role(string node_server_name, int node_server_port, role node_role, int node_balance, int node_partition) {
	string node_key = this->to_node_key(node_server_name, node_server_port);

	log_notice("set node role (node_key=%s, node_role=%d, node_balance=%d, node_partition=%d)", node_key.c_str(), node_role, node_balance, node_partition);

	coordinator::shared_operation operation;
	ostringstream msg;
	msg << "set node role " << node_key << " " << node_role << " " << node_balance << " " << node_partition;
	if (this->_coordinator->begin_operation(operation, msg.str()) < 0) {
		log_err("failed to begin operation for %s:%d", node_server_name.c_str(), node_server_port);
		return -1;
	}

	pthread_rwlock_wrlock(&this->_mutex_node_map);
	pthread_rwlock_wrlock(&this->_mutex_node_partition_map);
	try {
		if (this->_load() < 0) {
			log_warning("failed to load nodemap", 0);
			throw -1;
		}

		if (this->_node_map.count(node_key) == 0) {
			log_warning("no such node (node_key=%s)", node_key.c_str());
			throw -1;
		}

		node& n = this->_node_map[node_key];

		// state=down -> nothing to do
		if (n.node_state == state_down) {
			log_notice("failed to set node role [role=*, state=down] -> [role=*] not allowed", 0);
			throw -1;
		}

		// state=prepare|ready
		if (n.node_state == state_prepare || n.node_state == state_ready) {
			// current role=master
			if (n.node_role == role_master) {
				if (node_role == role_master) {
					if (this->_check_node_balance(node_key, node_balance) < 0) {
						throw -1;
					}
					n.node_balance = node_balance;
					log_notice("setting node balance [node_key=%s, node_balance=%d -> %d]", node_key.c_str(), n.node_balance, node_balance);
				} else if (node_role == role_slave) {
					log_notice("failed to set node role [role=master, state=prepare|ready] -> [role=slave] not allowed", 0);
					throw -1;
				} else if (node_role == role_proxy) {
					log_notice("clearing all slave nodes (partition=%d)", n.node_partition);
					for (vector<partition_node>::iterator it = this->_node_partition_prepare_map[n.node_partition].slave.begin(); it != this->_node_partition_prepare_map[n.node_partition].slave.end(); it++) {
						log_notice("  -> node_key: %s", it->node_key.c_str());
						this->_node_map[it->node_key].node_role = role_proxy;
						this->_node_map[it->node_key].node_state = state_active;
						this->_node_map[it->node_key].node_balance = 0;
						this->_node_map[it->node_key].node_partition = -1;
					}
					n.node_role = node_role;
					n.node_state = state_active;
					n.node_balance = 0;
					n.node_partition = -1;
					log_notice("setting node role [role=master, state=prepare] -> [role=proxy, state=active]", 0);
				}
			// role=slave
			} else if (n.node_role == role_slave) {
				if (node_role == role_master) {
					log_notice("failed to set node role [role=slave, state=prepare] -> [role=master] not allowed", 0);
					throw -1;
				} else if (node_role == role_slave) {
					bool preparing = false;
					if (this->_check_node_partition(n.node_partition, preparing) < 0) {
						throw -1;
					}
					if (preparing == false) {
						log_notice("updating node_balance is allowed only when master is also preparing (otherwise, it should always be 0)", 0);
						throw -1;
					}
					if (this->_check_node_balance(node_key, node_balance) < 0) {
						throw -1;
					}
					n.node_balance = node_balance;
					log_notice("setting node balance [node_key=%s, node_balance=%d -> %d]", node_key.c_str(), n.node_balance, node_balance);
				} else if (node_role == role_proxy) {
					// we do not have to check node balance here (<- state=prepare|ready)
					n.node_role = node_role;
					n.node_state = state_active;
					n.node_balance = 0;
					n.node_partition = -1;
					log_notice("setting node role [role=slave, state=prepare] -> [role=proxy, state=active]", 0);
				}
			} else if (n.node_role == role_proxy) {
				n.node_state = state_active;
				log_notice("setting node role [role=proxy, state=prepare|ready] -> something inconsistent -> shift state to active", 0);
			}
		}

		// state=active
		if (n.node_state == state_active) {
			// role=master
			if (n.node_role == role_master) {
				if (node_role == role_master) {
					if (this->_check_node_balance(node_key, node_balance) < 0) {
						throw -1;
					}
					n.node_balance = node_balance;
					log_notice("setting node balance [node_key=%s, node_balance=%d -> %d]", node_key.c_str(), n.node_balance, node_balance);
				} else {
					log_notice("failed to set node role [role=master, state=active] -> [role=slave|proxy] not allowed", 0);
					throw -1;
				}
			// role=slave
			} else if (n.node_role == role_slave) {
				if (node_role == role_master) {
					log_notice("failed to set node role [role=slave, state=active] -> [role=master] not allowed", 0);
					throw -1;
				} else if (node_role == role_slave) {
					if (this->_check_node_balance(node_key, node_balance) < 0) {
						throw -1;
					}
					n.node_balance = node_balance;
					log_notice("setting node balance [node_key=%s, node_balance=%d -> %d]", node_key.c_str(), n.node_balance, node_balance);
				} else if (node_role == role_proxy) {
					if (this->_check_node_balance(node_key, 0) < 0) {
						throw -1;
					}
					n.node_role = node_role;
					n.node_state = state_active;
					n.node_balance = 0;
					n.node_partition = -1;
					log_notice("setting node role [role=slave, state=active] -> [role=proxy, state=active]", 0);
				}
			// role=proxy
			} else if (n.node_role == role_proxy) {
				if (node_role == role_master) {
					// only new (next) partition is allowed
					bool preparing = false;
					if (this->_check_node_partition_for_new(node_partition, preparing) < 0) {
						throw -1;
					}
					if (node_balance <= 0) {
						log_notice("node_balance should be positive when adding new master node (node_balance=%d)", node_balance);
						throw -1;
					}
					n.node_role = node_role;
					// first partition (== 0) can start as active
					n.node_state = preparing ? (node_partition == 0 ? state_active : state_prepare) : state_active;
					n.node_balance = node_balance;
					n.node_partition = node_partition;
					log_notice("setting node role [role=proxy, state=active] -> [role=master, state=%s]", cluster::state_cast(n.node_state).c_str());
				} else if (node_role == role_slave) {
					bool preparing = false;
					if (this->_check_node_partition(node_partition, preparing) < 0) {
						throw -1;
					}
					if (preparing && node_balance < 0) {
						log_info("node_balance is set to 0 (given node_balance=%d)", node_balance);
						node_balance = 0;
					}
					n.node_role = node_role;
					n.node_state = state_prepare;
					n.node_balance = preparing ? node_balance : 0;
					n.node_partition = node_partition;
					log_notice("setting node role [role=proxy, state=active] -> [role=slave, state=prepare]", 0);
				} else if (node_role == role_proxy) {
					// nothing to do
				}
			}
		}

		this->_reconstruct_node_partition(false);
		if (this->_save() < 0) {
			log_err("failed to save nodemap and skip broadcasting", 0);
			throw -1;
		}
	} catch (int e) {
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		pthread_rwlock_unlock(&this->_mutex_node_map);
		this->_coordinator->end_operation(operation);
		return e;
	}
	pthread_rwlock_unlock(&this->_mutex_node_partition_map);
	pthread_rwlock_unlock(&this->_mutex_node_map);

	// notify - set node role
	shared_queue_node_sync q(new queue_node_sync(this));
	vector<string> dummy;
	this->_broadcast(q, false, dummy);

	this->_coordinator->end_operation(operation);
	return 0;
}

/**
 *	[index] set node state
 */
int cluster::set_node_state(string node_server_name, int node_server_port, state node_state) {
	string node_key = this->to_node_key(node_server_name, node_server_port);

	log_notice("set node state (node_key=%s, node_state=%d)", node_key.c_str(), node_state);
	if (node_state == state_prepare) {
		log_warning("currently (force) state shift to prepare is not yet supported", 0);
		return -1;
	}

	if (node_state == state_down) {
		return this->down_node(node_server_name, node_server_port);
	} else if (node_state == state_active) {
		return this->up_node(node_server_name, node_server_port);
	} else if (node_state == state_ready) {
		return this->ready_node(node_server_name, node_server_port);
	}

	return 0;
}

/*
 * [index] request node down
 */
int cluster::request_down_node(string node_server_name, int node_server_port) {
	shared_queue_node_state q(new queue_node_state(node_server_name, node_server_port, queue_node_state::state_operation_down));
	return this->_enqueue(q, thread_pool::thread_type_controller, false);
}

/*
 * [index] request node up
 */
int cluster::request_up_node(string node_server_name, int node_server_port) {
	shared_queue_node_state q(new queue_node_state(node_server_name, node_server_port, queue_node_state::state_operation_up));
	return this->_enqueue(q, thread_pool::thread_type_controller, false);
}

/**
 *	reconstruct all node map
 */
int cluster::reconstruct_node(vector<node> v, uint64_t node_map_version) {
	stack<node_shift_state> shift_state_stack;
	stack<node_shift_role> shift_role_stack;

	pthread_rwlock_wrlock(&this->_mutex_node_map);
	pthread_rwlock_wrlock(&this->_mutex_node_partition_map);

	if (this->get_node_map_version() > 0 && this->get_node_map_version() > node_map_version) {
		log_notice("ignored: the current node_map_version (%llu) is newer than (%llu)", this->get_node_map_version(), node_map_version);
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		pthread_rwlock_unlock(&this->_mutex_node_map);
		return -1;
	}

	log_notice("reconstructing node map... (%d entries)", v.size());

	node_map nm;

	for (vector<node>::iterator it = v.begin(); it != v.end(); it++) {
		string node_key = this->to_node_key(it->node_server_name, it->node_server_port);
		log_debug("node_key: %s%s", node_key.c_str(), node_key == this->_node_key ? " (myself)" : "");

		if (this->_type == type_node) {
			if (this->_node_map.count(node_key) == 0) {
				// in this case, logically we do not have to handle anything
				// - myself -> should be role=proxy
				// - others -> this node does not have to care about anything
				log_debug("-> new node", 0);
			} else {
				log_debug("-> existing node", 0);
				if (it->node_state != this->_node_map[node_key].node_state) {
					node_shift_state tmp = { node_key, this->_node_map[node_key].node_state, it->node_state};
					shift_state_stack.push(tmp);
				}
				if (it->node_role != this->_node_map[node_key].node_role || it->node_partition != this->_node_map[node_key].node_partition) {
					node_shift_role tmp = {node_key, this->_node_map[node_key].node_role, this->_node_map[node_key].node_partition, it->node_role, it->node_partition};
					shift_role_stack.push(tmp);
				}

				if (it->node_balance != this->_node_map[node_key].node_balance) {
					log_notice("update: node_balance (%d -> %d)", this->_node_map[node_key].node_balance, it->node_balance);
				}
				if (it->node_thread_type != this->_node_map[node_key].node_thread_type) {
					// this should not happen
					log_err("update: node_thread_type (%d -> %d)", this->_node_map[node_key].node_thread_type, it->node_thread_type);
				}
				this->_node_map.erase(node_key);
			}
		}
		nm[node_key] = *it;
	}

	// check out removed nodes
	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		log_notice("detecting removed node [node_key=%s]", it->first.c_str());

		// do something?
	}

	this->_node_map = nm;

	this->_reconstruct_node_partition(false);

	while (shift_state_stack.size() > 0) {
		node_shift_state tmp = shift_state_stack.top();
		this->_shift_node_state(tmp.node_key, tmp.old_state, tmp.new_state);
		shift_state_stack.pop();
	}

	while (shift_role_stack.size() > 0) {
		node_shift_role tmp = shift_role_stack.top();
		this->_shift_node_role(tmp.node_key, tmp.old_role, tmp.old_partition, tmp.new_role, tmp.new_partition);
		shift_role_stack.pop();
	}

	this->_set_node_map_version(node_map_version);

	pthread_rwlock_unlock(&this->_mutex_node_partition_map);
	pthread_rwlock_unlock(&this->_mutex_node_map);

	return 0;
}

/**
 *	[index] set node server monitoring threshold
 */
int cluster::set_monitor_threshold(int monitor_threshold) {
	this->_monitor_threshold = monitor_threshold;

	// notify current threads
	shared_queue_update_monitor_option q(new queue_update_monitor_option(this->_monitor_threshold, this->_monitor_interval, this->_monitor_read_timeout));
	vector<string> dummy;
	this->_broadcast(q, true, dummy);

	return 0;
}

/**
 *	[index] set node server monitoring interval
 */
int cluster::set_monitor_interval(int monitor_interval) {
	this->_monitor_interval = monitor_interval;

	// notify current threads
	shared_queue_update_monitor_option q(new queue_update_monitor_option(this->_monitor_threshold, this->_monitor_interval, this->_monitor_read_timeout));
	vector<string> dummy;
	this->_broadcast(q, true, dummy);

	return 0;
}

/**
 *	[index] set node server monitoring read timeout
 */
int cluster::set_monitor_read_timeout(int monitor_read_timeout) {
	this->_monitor_read_timeout = monitor_read_timeout;

	// notify current threads
	shared_queue_update_monitor_option q(new queue_update_monitor_option(this->_monitor_threshold, this->_monitor_interval, this->_monitor_read_timeout));
	vector<string> dummy;
	this->_broadcast(q, true, dummy);

	return 0;
}

/**
 *	[node] activate node (prepare -> ready)
 */
int cluster::activate_node(bool skip_ready_state) {
	shared_connection c = this->_open_index();
	if (!c) {
		log_err("failed to connect to index server", 0);
		return -1;
	}

	op_node_state* p = new op_node_state(c, this);
	state new_state = skip_ready_state ? state_active : state_ready;
	if (p->run_client(this->_server_name, this->_server_port, new_state) < 0 || p->get_result() != op::result_ok) {
		log_err("failed to activate node", 0);
		delete p;
		return -1;
	}
	delete p;

	return 0;
}

/**
 *	[node] deactivate node (* -> proxy)
 */
int cluster::deactivate_node() {
	shared_connection c = this->_open_index();
	if (!c) {
		log_err("failed to connect to index server", 0);
		return -1;
	}

	op_node_role* p = new op_node_role(c, this);
	if (p->run_client(this->_server_name, this->_server_port, role_proxy, 0, -1) < 0 || p->get_result() != op::result_ok) {
		log_err("failed to deactivate node", 0);
		delete p;
		return -1;
	}
	delete p;

	return 0;
}

/**
 *  [node] send shutdown message upon receiving a SIGTERM.
 */
int cluster::shutdown_node() {
	shared_connection c = this->_open_index();
	if (!c) {
		log_err("failed to connect to index server", 0);
		return -1;
	}

	op_shutdown* p = new op_shutdown(c, this);
	if (p->run_client(this->_server_name, this->_server_port) < 0 || p->get_result() != op::result_ok) {
		log_err("failed to send shutdown message", 0);
		delete p;
		return -1;
	}
	delete p;

	return 0;
}

/**
 *	[node] pre proxy for reading ops (get, gets)
 *
 *	@todo fix performance issue
 */
cluster::proxy_request cluster::pre_proxy_read(op_proxy_read* op, storage::entry& e, void* parameter, shared_queue_proxy_read& q_result) {
	partition p;
	bool dummy;
	int n = this->_determine_partition(e, p, false, dummy);
	if (n < 0) {
		// perhaps no partition available
		return proxy_request_error_partition;
	}

	if (p.master.node_key == this->_node_key) {
		return proxy_request_continue;
	}
	for (vector<partition_node>::iterator it = p.slave.begin(); it != p.slave.end(); it++) {
		if (it->node_balance > 0 && it->node_key == this->_node_key) {
			return proxy_request_continue;
		}
	}

	// select one (rand() will do)
	if (p.balance.size() == 0) {
		log_err("no node is available for this partition (all balances are set to 0)", 0);
		return proxy_request_error_partition;
	}

	string node_key;
	if (p.prior_balance.size() > 0) {
		node_key = p.prior_balance[rand() % p.prior_balance.size()];
	} else {
		node_key = p.balance[rand() % p.balance.size()];
	}
	log_debug("selected proxy node (node_key=%s)", node_key.c_str());

	vector<string> proxy = op->get_proxy();
	proxy.push_back(this->_node_key);
	shared_queue_proxy_read q(new queue_proxy_read(this, this->_storage, proxy, e, parameter, op->get_ident()));
	if (this->_enqueue(static_pointer_cast<thread_queue, queue_proxy_read>(q), node_key, e.get_key_hash_value(this->_proxy_hash_algorithm), true) < 0) {
		return proxy_request_error_enqueue;
	}
	q_result = q;
	
	return proxy_request_complete;
}

/**
 *	[node] pre proxy for writing ops (set, add, replace, append, prepend, cas, incr, decr)
 *
 *	@todo fix performance issue
 */
cluster::proxy_request cluster::pre_proxy_write(op_proxy_write* op, shared_queue_proxy_write& q_result, uint64_t generic_value) {
	storage::entry& e = op->get_entry();

	partition p, p_prepare;
	bool is_prepare;
	int n = this->_determine_partition(e, p, false, is_prepare);
	if (n < 0) {
		// perhaps no partition available
		return proxy_request_error_partition;
	}
	this->_determine_partition(e, p_prepare, true, is_prepare);

	if (p.master.node_key == this->_node_key || (op->is_proxy_request() && is_prepare && p_prepare.master.node_key == this->_node_key)) {
		// should be write at this node
		return proxy_request_continue;
	}

	if (op->is_proxy_request()) {
		if (p.index.count(this->_node_key) > 0 || (is_prepare && p_prepare.index.count(this->_node_key) > 0)) {
			return proxy_request_continue;
		}
	}

	// proxy request to master
	bool sync = (e.option & storage::option_noreply) ? false : true;
	vector<string> proxy = op->get_proxy();
	proxy.push_back(this->_node_key);
	shared_queue_proxy_write q(new queue_proxy_write(this, this->_storage, proxy, e, op->get_ident()));
	q->set_generic_value(generic_value);
	if (this->_enqueue(static_pointer_cast<thread_queue, queue_proxy_write>(q), p.master.node_key, e.get_key_hash_value(this->_proxy_hash_algorithm), sync) < 0) {
		return proxy_request_error_enqueue;
	}
	if (sync) {
		q->sync();
		q_result = q;
	}
	
	return proxy_request_complete;
}

/**
 *	[node] post proxy for writing ops
 */
cluster::proxy_request cluster::post_proxy_write(op_proxy_write* op, bool sync) {
	storage::entry& e = op->get_entry();

	partition p, p_prepare;
	bool is_prepare;
	int n = 0;
	n = this->_determine_partition(e, p, false, is_prepare);
	if (n < 0) {
		// perhaps no partition available
		return proxy_request_error_partition;
	}
	this->_determine_partition(e, p_prepare, true, is_prepare);

	if ((p.master.node_key == this->_node_key) || (op->is_proxy_request() && is_prepare && p_prepare.master.node_key == this->_node_key)) {
		// fall through
	} else {
		// nothing to do
		return proxy_request_complete;
	}

	int key_hash_value = e.get_key_hash_value(this->_proxy_hash_algorithm);
	vector<string> proxy = op->get_proxy();
	if (static_cast<int>(count(proxy.begin(), proxy.end(), this->_node_key)) >= 2) {
		// nothing to do
		// The following cases may occur. (count() == 1, w/failover)
		// e.g.) client -> nodeA(slave) -> nodeB(preparing, changed role from master to slave) -> nodeA(master, failovered) -> nodeB
		//                                                                                        ^^^^^
		log_warning("skip proxy request to slave -> storing proxied node list (n=%d, proxy=%s)", proxy.size(), util::vector_join<string>(proxy, ",").c_str());
		return proxy_request_complete;
	}
	proxy.push_back(this->_node_key);
	shared_queue_proxy_write q(new queue_proxy_write(this, this->_storage, proxy, e, op->get_ident()));
	q->set_post_proxy(true);

	partition& p_tmp = (is_prepare && p_prepare.master.node_key == this->_node_key) ? p_prepare : p;
	for (vector<partition_node>::iterator it = p_tmp.slave.begin(); it != p_tmp.slave.end(); it++) {
		// proxy request to slave
		log_debug("proxy request to slave (node_key=%s, ident=%s)", it->node_key.c_str(), op->get_ident().c_str());
		if (this->_enqueue(q, it->node_key, key_hash_value, sync) < 0) {
			log_warning("enqueue failed (node_key=%s) -> continue processing", it->node_key.c_str());
			continue;
		}
	}
#ifdef ENABLE_MYSQL_REPLICATION
	if (this->_mysql_replication) {
		this->_enqueue(q, thread_pool::thread_type_mysql_replication, sync);
		// no follow up...?
	}
#endif
	if (sync) {
		q->sync();
	}

	// proxy to preparing master (if we need)
	if (is_prepare && p.master.node_key == this->_node_key) {
		log_debug("proxy request to preparing master (node_key=%s, ident=%s)", p_prepare.master.node_key.c_str(), op->get_ident().c_str());
		if (this->_enqueue(q, p_prepare.master.node_key, key_hash_value, sync) < 0) {
			log_warning("enqueue failed (node_key=%s) -> continue processing", p_prepare.master.node_key.c_str());
			// no follow up...?
		}
	}

	return proxy_request_complete;
}
// }}}

// {{{ protected methods
/**
 *	[node] shift node state
 *
 *	assumes that node_map and node_partition_map is alreadby write locked
 */
int cluster::_shift_node_state(string node_key, state old_state, state new_state) {
	log_notice("shifting node_state (node_key=%s, old_state=%s, new_state=%s)", node_key.c_str(), cluster::state_cast(old_state).c_str(), cluster::state_cast(new_state).c_str());

	if (node_key == this->_node_key) {
		// nothing to do?
	} else {
		// TODO: queue failover if we need
	}

	return 0;
}

/**
 *	[node] shift node role (and partition)
 *
 *	assumes that node_map and node_partition_map is already write locked
 */
int cluster::_shift_node_role(string node_key, role old_role, int old_partition, role new_role, int new_partition) {
	log_notice("shifting node_role (node_key=%s, old_role=%s, old_partition=%d, new_role=%s, new_partition=%d)", node_key.c_str(), cluster::role_cast(old_role).c_str(), old_partition, cluster::role_cast(new_role).c_str(), new_partition);

	if (node_key != this->_node_key) {
		// we do not have to care about other nodes (maybe?)
		return 0;
	}
	if (new_role == role_proxy) {
		// we do not have to care about anything in this case, too (maybe?)
		return 0;
	}

	// proxy -> slave or master: requesting reconstruction
	// we intentionally do not truncate current database here (for safe)
	// if user *really* want to reconstruct database, they can use "flush_all" op
	log_debug("creating reconstruction thread(s)... (type=%s)", cluster::role_cast(new_role).c_str());
	if (new_role == role_master && old_role == role_proxy) {
		int partition_size = this->_node_partition_map.size() + this->_node_partition_prepare_map.size();
		log_debug("partition_size: %d", partition_size);
		for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
			log_debug("node_key: %s, node_role=%s, node_state=%s", it->first.c_str(), cluster::role_cast(it->second.node_role).c_str(), cluster::state_cast(it->second.node_state).c_str());
			if (it->first == node_key || it->second.node_role != role_master || it->second.node_state != state_active) {
				continue;
			}
			log_debug("determined reconstruction source node (node_key=%s, partition=%d, new_role=%s, new_partition=%d)", it->first.c_str(), it->second.node_partition, cluster::role_cast(new_role).c_str(), new_partition);

			pthread_mutex_lock(&this->_mutex_master_reconstruction);
			this->_master_reconstruction++;
			pthread_mutex_unlock(&this->_mutex_master_reconstruction);

			shared_thread t = this->_thread_pool->get(thread_pool::thread_type_reconstruction);
			string node_server_name;
			int node_server_port = 0;
			this->from_node_key(it->first, node_server_name, node_server_port);
			handler_reconstruction* h = new handler_reconstruction(
				t,
				this,
				this->_storage,
				node_server_name,
				node_server_port,
				new_partition,
				partition_size,
				new_role,
				this->get_reconstruction_interval(),
				this->_get_reconstruction_bwlimit_for_new_partition(this->_node_partition_map.size())
			);
			t->trigger(h);
		}
		pthread_mutex_lock(&this->_mutex_master_reconstruction);
		log_notice("master reconstruction started (n=%d)", this->_master_reconstruction);
		pthread_mutex_unlock(&this->_mutex_master_reconstruction);
	} else if (new_role == role_slave && old_role == role_proxy) {
		string master_node_key = "";
		int partition_size = this->_node_partition_map.size();
		if (this->_node_partition_map.count(new_partition) > 0) {
			master_node_key = this->_node_partition_map[new_partition].master.node_key;
			log_debug("determined reconstruction source node (type=active master_node_key=%s)", master_node_key.c_str());
		} else if (this->_node_partition_prepare_map.count(new_partition) > 0) {
			master_node_key = this->_node_partition_prepare_map[new_partition].master.node_key;
			log_debug("determined reconstruction source node (type=prepare master_node_key=%s)", master_node_key.c_str());
			partition_size += this->_node_partition_prepare_map.size();
		} else {
			log_err("could not find reconstruction source node (node_key=%s, new_role=%s, new_partition=%d) -> deactivating node", node_key.c_str(), cluster::role_cast(new_role).c_str(), new_partition);
			this->deactivate_node();
			return -1;
		}
		
		shared_thread t = this->_thread_pool->get(thread_pool::thread_type_reconstruction);
		string node_server_name;
		int node_server_port = 0;
		this->from_node_key(master_node_key, node_server_name, node_server_port);
		handler_reconstruction* h = new handler_reconstruction(t, this, this->_storage, node_server_name, node_server_port, new_partition, partition_size, new_role, this->get_reconstruction_interval(), this->get_reconstruction_bwlimit());
		t->trigger(h);
	}

	return 0;
}

int cluster::_enqueue(shared_thread_queue q, string node_key, int key_hash, bool sync) {
	log_debug("enqueue (ident=%s, node_key=%s, key_hash=%d)", q->get_ident().c_str(), node_key.c_str(), key_hash);

	shared_thread t;
	if (this->_get_proxy_thread(node_key, key_hash, t) < 0) {
		return -1;
	}

	if (sync) {
		q->sync_ref();
	}
	if (t->enqueue(q, this->_max_total_thread_queue) < 0) {
		log_warning("enqueue failed (perhaps thread is now exiting?)", 0);
		if (sync) {
			q->sync_unref();
		}
		return -1;
	}

	return 0;
}

int cluster::_enqueue(shared_thread_queue q, thread_pool::thread_type type, bool sync) {
	log_debug("enqueue (ident=%s, thread_type=%d)", q->get_ident().c_str(), type);

	shared_thread t;
	thread_pool::local_map m = this->_thread_pool->get_active(type);
	thread_pool::local_map::iterator it = m.begin();
	if (it == m.end()) {
		return -1;
	}
	t = it->second;

	if (sync) {
		q->sync_ref();
	}
	if (t->enqueue(q) < 0) {
		log_warning("enqueue failed (perhaps thread is now exiting?)", 0);
		if (sync) {
			q->sync_unref();
		}
		return -1;
	}

	return 0;
}

/**
 *	broadcast thread_queue to all node servers
 *	
 *	[notice] all threads receive same thread_queue object
 */
int cluster::_broadcast(shared_thread_queue q, bool sync, vector<string> prior_node_key, string exclude_node_key) {
	log_debug("broadcasting queue [ident=%s]", q->get_ident().c_str());

	// handle prior node key first
	if (prior_node_key.size() > 0) {
		bool sync_for_proior_nodes = false;
		pthread_rwlock_rdlock(&this->_mutex_node_map);
		for (vector<string>::iterator it = prior_node_key.begin(); it != prior_node_key.end(); it++) {
			string p = *it;
			if (exclude_node_key == p) {
				log_notice("node key = %s skip enqueue", exclude_node_key.c_str());
				continue;
			}

			log_notice("prior node key = %s -> process target node first w/ sync mode", p.c_str());
			thread_pool::local_map m = this->_thread_pool->get_active(this->_node_map[p].node_thread_type);

			int n = 0;
			for (thread_pool::local_map::iterator it_local = m.begin(); it_local != m.end(); it_local++) {
				if (it_local->second->is_myself()) {
					log_warning("thread is myself -> skip enqueue (<- will cause dead lock) (id=%d, thread_id=%d)", it_local->first, it_local->second->get_thread_id());
					continue;
				}
				q->sync_ref();
				if (it_local->second->enqueue(q) < 0) {
					log_warning("enqueue failed (perhaps thread is now exiting?)", 0);
					q->sync_unref();
					continue;
				}
				log_debug("  -> enqueue (id=%d)", it_local->first);
				n++;

				// only 1 queue for each node
				break;
			}
			if (n > 0) {
				sync_for_proior_nodes = true;
			}
		}
		pthread_rwlock_unlock(&this->_mutex_node_map);
		if (sync_for_proior_nodes) {
			q->sync();
		}
	}

	// TODO: see if thread is myself or not to avoid dead locks
	pthread_rwlock_rdlock(&this->_mutex_node_map);
	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		if (exclude_node_key == it->first) {
			log_notice("node key = %s skip enqueue", exclude_node_key.c_str());
			continue;
		}
		thread_pool::local_map m = this->_thread_pool->get_active(it->second.node_thread_type);
		for (thread_pool::local_map::iterator it_local = m.begin(); it_local != m.end(); it_local++) {
			if (sync) {
				q->sync_ref();
			}
			if (it_local->second->enqueue(q) < 0) {
				log_warning("enqueue failed (perhaps thread is now exiting?)", 0);
				if (sync) {
					q->sync_unref();
				}
				continue;
			}
			log_debug("  -> enqueue (id=%d)", it_local->first);

			// only 1 queue for each node
			break;
		}
	}
	pthread_rwlock_unlock(&this->_mutex_node_map);

	if (sync) {
		q->sync();
	}

	return 0;
}

/**
 *	save node variables
 *  Note that this function doesn't acquire the lock for this->_node_map.
 */
int cluster::_save() {
	if (this->_coordinator == NULL) {
		log_err("coordinator not initialized", 0);
		return -1;
	}

	pthread_mutex_lock(&this->_mutex_serialization);
	this->_increment_node_map_version();

	ostringstream oss;
	// creating scope to destroy xml_oarchive object before ostringstream::close();
	{
		archive::xml_oarchive oa(oss);
		oa << serialization::make_nvp("version", (const uint64_t&)this->_node_map_version);
		oa << serialization::make_nvp("node_map", (const node_map&)this->_node_map);
		oa << serialization::make_nvp("thread_type", (const int&)this->_thread_type);
	}

	string flare_xml = oss.str();
	if (this->_coordinator->store_state(flare_xml) < 0) {
		log_err("failed to store node variables", 0);
		pthread_mutex_unlock(&this->_mutex_serialization);
		return -1;
	}

	pthread_mutex_unlock(&this->_mutex_serialization);
	return 0;
}

/**
 *	load node variables
 *  Note that this function doesn't acquire the lock for this->_node_map.
 */
int cluster::_load(bool update_monitor) {
	if (this->_coordinator == NULL) {
		log_err("coordinator not initialized", 0);
		return -1;
	}

	map<string, node> preserved_node_map = this->_node_map;

	pthread_mutex_lock(&this->_mutex_serialization);
	string flare_xml;
	if (this->_coordinator->restore_state(flare_xml) < 0) {
		pthread_mutex_unlock(&this->_mutex_serialization);
		log_err("failed to restore state", 0);
		return -1;
	}
	if (!flare_xml.empty()) {
		try {
			istringstream iss(flare_xml);
			archive::xml_iarchive ia(iss);
			ia >> serialization::make_nvp("version", this->_node_map_version);
			ia >> serialization::make_nvp("node_map", this->_node_map);
			ia >> serialization::make_nvp("thread_type", this->_thread_type);
		} catch (archive::archive_exception& e) {
			try {
				istringstream iss(flare_xml);
				archive::xml_iarchive ia(iss);
				this->_node_map_version = 0;
				ia >> serialization::make_nvp("node_map", this->_node_map);
				ia >> serialization::make_nvp("thread_type", this->_thread_type);
			} catch (archive::archive_exception& e) {
				pthread_mutex_unlock(&this->_mutex_serialization);
				log_err("invalid XML format", 0);
				return -1;
			}
		}
	}

	// sanity check
	for (node_map::const_iterator it_node = this->_node_map.begin();
			 it_node != this->_node_map.end();
			 ++it_node) {
		if (it_node->second.node_thread_type >= this->_thread_type) {
			pthread_mutex_unlock(&this->_mutex_serialization);
			log_err("node %s has a thread_type (%d) greater or equal to the global thread_type value (%d)",
							it_node->first.c_str(),
							it_node->second.node_thread_type,
							this->_thread_type);
			return -1;
		}
	}

	pthread_mutex_unlock(&this->_mutex_serialization);

	if (update_monitor) {
		// kill monitoring threads
		for (node_map::iterator it = preserved_node_map.begin(); it != preserved_node_map.end(); it++) {
			if (this->_node_map.count(it->first) == 0) {
				thread_pool::local_map m = this->_thread_pool->get_active(it->second.node_thread_type);
				for (thread_pool::local_map::iterator tit = m.begin(); tit != m.end(); tit++) {
					log_notice("killing monitoring thread(s)... (node_thread_type=%d, thread_id=%d)",
										 it->second.node_thread_type, tit->second->get_id());
					tit->second->set_state("killed");
					tit->second->shutdown(true, false);
				}
			}
		}

		// create monitoring threads
		for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
			if (preserved_node_map.count(it->first) == 0) {
				shared_thread t = this->_thread_pool->get(it->second.node_thread_type);
				handler_monitor* h = new handler_monitor(t, this, it->second.node_server_name, it->second.node_server_port);
				h->set_monitor_threshold(this->_monitor_threshold);
				h->set_monitor_interval(this->_monitor_interval);
				h->set_monitor_read_timeout(this->_monitor_read_timeout);
				t->trigger(h);
			}
		}
	}

	return 0;
}

void cluster::_update() {
	log_notice("updating node partition map", 0);

	pthread_rwlock_wrlock(&this->_mutex_node_map);
	pthread_rwlock_wrlock(&this->_mutex_node_partition_map);
	if (this->_load() < 0) {
		log_warning("failed to load nodemap", 0);
	} else {
		this->_reconstruct_node_partition(false);
	}
	pthread_rwlock_unlock(&this->_mutex_node_partition_map);
	pthread_rwlock_unlock(&this->_mutex_node_map);
}

/**
 *	reconstruct node partition map from current node map
 */
int cluster::_reconstruct_node_partition(bool lock) {
	int r = 0;

	if (lock) {
		pthread_rwlock_rdlock(&this->_mutex_node_map);
		pthread_rwlock_wrlock(&this->_mutex_node_partition_map);
	}

	log_notice("reconstructing node partition map... (from %d entries in node map)", this->_node_map.size());

	node_partition_map npm;
	node_partition_map nppm;

	const in_addr_t network_addr = util::inet_addr(this->_server_name.c_str(), this->_proxy_prior_netmask);
	log_debug("network address (myself): %u", network_addr);

	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		// master (1st path)
		node& n = it->second;
		if (n.node_role != role_master) {
			continue;
		}
		if (n.node_state == state_down) {
			// this means that we should preserve this partition (even if it's empty)
			if (npm[n.node_partition].master.node_key.empty()) {
				npm[n.node_partition].master.node_key = "";
				npm[n.node_partition].master.node_balance = 0;
				log_notice("role is master but state is down -> preserve as empty partition (node_key=%s, partition=%d)", it->first.c_str(), n.node_partition);
				continue;
			}
		}

		string node_key = it->first;
		log_debug("node_key: %s%s", node_key.c_str(), node_key == this->_node_key ? " (myself)" : "");

		try {
			if (n.node_partition < 0) {
				throw "node partition is inconsistent (role=master but have no partition)";
			}

			if (n.node_state == state_active) {
				if (npm[n.node_partition].master.node_key.empty() == false) {
					throw "master is already set, cannot overwrite";
				}
				npm[n.node_partition].master.node_key = node_key;
				npm[n.node_partition].master.node_balance = n.node_balance;

				for (int i = 0; i < n.node_balance; i++) {
					npm[n.node_partition].balance.push_back(node_key);
				}
				npm[n.node_partition].index[node_key] = true;

				log_debug("master node added (node_key=%s, partition=%d, balance=%d)", node_key.c_str(), n.node_partition, n.node_balance);

				if (this->_proxy_prior_netmask == 0) {
					continue;
				}
				const in_addr_t addr = util::inet_addr(n.node_server_name.c_str(), this->_proxy_prior_netmask);
				log_debug("master network address %s:%u", node_key.c_str(), addr);
				if (network_addr == addr) {
					for (int i = 0; i < n.node_balance; i++) {
						npm[n.node_partition].prior_balance.push_back(node_key);
					}
				}
			} else if (n.node_state == state_prepare || n.node_state == state_ready) {
				if (nppm[n.node_partition].master.node_key.empty() == false) {
					throw "master (prepare) is already set, cannot overwrite";
				}
				nppm[n.node_partition].master.node_key = node_key;
				nppm[n.node_partition].master.node_balance = n.node_balance;

				for (int i = 0; i < n.node_balance; i++) {
					nppm[n.node_partition].balance.push_back(node_key);
				}
				nppm[n.node_partition].index[node_key] = true;

				log_debug("master (prepare) node added (node_key=%s, partition=%d, balance=%d)", node_key.c_str(), n.node_partition, n.node_balance);
			}
		} catch (const char* e) {
			log_err("%s [node_key=%s, state=%d, role=%d, partition=%d]", e, node_key.c_str(), n.node_state, n.node_role, n.node_partition);
			r = -1;
		}
	}

	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		// slave (2nd path)
		node& n = it->second;
		if (n.node_role != role_slave || n.node_state == state_down) {
			continue;
		}

		string node_key = it->first;
		try {
			if (n.node_partition < 0) {
				throw "node partition is inconsistent (role=slave but have no partition)";
			}

			partition_node pn;
			if (n.node_state == state_active) {
				pn.node_key = node_key;
				pn.node_balance = n.node_balance;
			} else {
				pn.node_key = node_key;
				pn.node_balance = 0;		// should be always 0 for safe
			}

			if (npm.count(n.node_partition) > 0) {
				npm[n.node_partition].slave.push_back(pn);
				for (int i = 0; i < pn.node_balance; i++) {
					npm[n.node_partition].balance.push_back(node_key);
				}
				npm[n.node_partition].index[node_key] = true;

				if (this->_proxy_prior_netmask == 0) {
					continue;
				}
				const in_addr_t addr = util::inet_addr(n.node_server_name.c_str(), this->_proxy_prior_netmask);
				log_debug("network address %s:%u", node_key.c_str(), addr);
				if (network_addr == addr) {
					for (int i = 0; i < pn.node_balance; i++) {
						npm[n.node_partition].prior_balance.push_back(node_key);
					}
				}
			} else if (nppm.count(n.node_partition) > 0) {
				nppm[n.node_partition].slave.push_back(pn);
				for (int i = 0; i < pn.node_balance; i++) {
					nppm[n.node_partition].balance.push_back(node_key);
				}
				nppm[n.node_partition].index[node_key] = true;
			} else {
				throw "no node partition for this slave";
			}
		} catch (const char *e) {
			log_err("%s [node_key=%s, state=%d, role=%d, partition=%d]", e, node_key.c_str(), n.node_state, n.node_role, n.node_partition);
			r = -1;
		}
	}

	// check and log node partition map consistency
	try {
		int n = 0;
		log_notice("node partition map:", 0);
		for (node_partition_map::iterator it = npm.begin(); it != npm.end(); it++) {
			if (it->first > n) {
				n = it->first;
			}
			log_notice("%d: master (node_key=%s, node_balance=%d)", it->first, it->second.master.node_key.c_str(), it->second.master.node_balance);

			int m = 0;
			for (vector<partition_node>::iterator it_slave = it->second.slave.begin(); it_slave != it->second.slave.end(); it_slave++) {
				log_notice("%d: slave[%d] (node_key=%s, node_balance=%d)", it->first, m, it_slave->node_key.c_str(), it_slave->node_balance);
				m++;
			}
		}
		if (npm.size() > 0 && (n+1) != static_cast<int>(npm.size())) {
			log_err("possibly missing partition (partition=%d, size=%d)", n, npm.size());
			throw -1;
		}

		n = 0;
		log_notice("node partition map (prepare):", 0);
		if (nppm.size() > 1) {
			log_err("more than 1 partition prepare map -> something is seriously going wrong", 0);
			throw -1;
		}

		for (node_partition_map::iterator it = nppm.begin(); it != nppm.end(); it++) {
			if (it->first != static_cast<int>(npm.size())) {
				// allow only 1 and next partition
				log_err("invalid partition [%d] for partition prepare map -> something is seriously going wrong", it->first);
				throw -1;
			}

			log_notice("%d(prepare): master (node_key=%s, node_balance=%d)", it->first, it->second.master.node_key.c_str(), it->second.master.node_balance);

			int m = 0;
			for (vector<partition_node>::iterator it_slave = it->second.slave.begin(); it_slave != it->second.slave.end(); it_slave++) {
				log_notice("%d(prepare): slave[%d] (node_key=%s, node_balance=%d)", it->first, m, it_slave->node_key.c_str(), it_slave->node_balance);
				m++;
			}
		}
	} catch (int e) {
		if (lock) {
			pthread_rwlock_unlock(&this->_mutex_node_partition_map);
			pthread_rwlock_unlock(&this->_mutex_node_map);
		}
		return -1;
	}

	this->_node_partition_map = npm;
	this->_node_partition_prepare_map = nppm;

	if (lock) {
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		pthread_rwlock_unlock(&this->_mutex_node_map);
	}

	return r;
}

/**
 *	check if node balance is valid
 *
 *	caller *should* lock node_map in advance
 */
int cluster::_check_node_balance(string node_key, int node_balance) {
	int n = 0;
	if (node_balance < 0) {
		log_warning("node_balance is negative (node_key=%s, node_balance=%d)", node_key.c_str(), node_balance);
		return -1;
	}
	if (this->_node_map.count(node_key) == 0) {
		log_warning("no such node (node_key=%s)", node_key.c_str());
		return -1;
	}
	int node_partition = this->_node_map[node_key].node_partition;
	if (node_partition < 0) {
		log_warning("node_partition is invalid -> cannot check (node_partition=%d)", node_partition);
		return -1;
	}

	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		if (it->first == node_key) {
			n += node_balance;
		} else if (it->second.node_partition == node_partition) {
			n += it->second.node_balance;
		}
	}

	if (n == 0) {
		log_warning("node_balance is invalid (this will cause zero-sum-balance) (node_key=%s, node_partition=%d, node_balance=%d)", node_key.c_str(), node_partition, node_balance);
		return -1;
	}

	return 0;
}

/**
 *	check if given node partition is valid for new slave
 *
 *	caller *should* lock node_map in advance
 */
int cluster::_check_node_partition(int node_partition, bool& preparing) {
	if (node_partition < 0) {
		log_warning("node_partition is negative (node_partition=%d)", node_partition);
		return -1;
	}

	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		if (it->second.node_role != role_master || it->second.node_state == state_down) {
			continue;
		}
		if (it->second.node_partition == node_partition) {
			preparing = it->second.node_state == state_active ? false : true;
			return 0;
		}
	}

	return -1;
}

/**
 *	check if given node partition is valid for new partition
 *
 *	caller *should* lock node_map in advance
 */
int cluster::_check_node_partition_for_new(int node_partition, bool& preparing) {
	if (node_partition > static_cast<int>(this->_node_partition_map.size()) || node_partition < 0) {
		log_warning("node_partition should be %d or less than it, and positive (given node_partition=%d) (currently only next partition or replacing down master node is allowed)", this->_node_partition_map.size(), node_partition);
		return -1;
	}

	if (node_partition == static_cast<int>(this->_node_partition_map.size())) {
		// see if we already have one
		for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
			if (it->second.node_role == role_master && it->second.node_partition == node_partition) {
				log_warning("already have same node partition (node_key=%s, node_state=%d, node_partition=%d)", it->first.c_str(), node_partition, it->second.node_state);
				return -1;
			}
		}
		preparing = true;
	} else {
		for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
			if (it->second.node_role == role_master && it->second.node_partition == node_partition) {
				if (it->second.node_state == state_down) {
					log_notice("already have same node partition but state is down -> replacable (node_key=%s, node_state=%d, node_partition=%d)", it->first.c_str(), node_partition, it->second.node_state);
				} else {
					log_warning("already have same node partition (node_key=%s, node_state=%d, node_partition=%d)", it->first.c_str(), node_partition, it->second.node_state);
					return -1;
				}
			}
		}
		preparing = false;
	}

	return 0;
}

int cluster::_determine_partition(storage::entry& e, partition& p, bool check_prepare, bool& is_prepare) {
	pthread_rwlock_rdlock(&this->_mutex_node_partition_map);
	int n;
	is_prepare = false;
	try {
		if (this->_node_partition_map.size() <= 0) {
			log_warning("no partition is available", 0);
			throw -1;
		}

		int partition_size = this->_node_partition_map.size();
		if (check_prepare) {
			partition_size += this->_node_partition_prepare_map.size();
		}
		n = this->_key_resolver->resolve(e.get_key_hash_value(this->_key_hash_algorithm), partition_size);
		log_debug("determined partition (key=%s, n=%d)", e.key.c_str(), n);

		if (check_prepare) {
			if (this->_node_partition_prepare_map.count(n) > 0) {
				is_prepare = true;
				p = this->_node_partition_prepare_map[n];
			}
		}

		if (is_prepare == false) {
			if (this->_node_partition_map.count(n) == 0) {
				log_err("have no partition map for this key (key=%s, n=%d, size=%d)", e.key.c_str(), n, this->_node_partition_map.size());
				throw -1;
			}
			p = this->_node_partition_map[n];
		}
	} catch (int error) {
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		return error;
	}
	pthread_rwlock_unlock(&this->_mutex_node_partition_map);

	return n;
}

string cluster::_get_partition_key(string key) {
	string::size_type m = key.find_first_of("{{");
	if (m == string::npos) {
		return key;
	}
	string::size_type n = key.find_first_of("}}", m+1);
	if (n == string::npos) {
		return key;
	}

	string s = key.substr(m+2, n-m-2);
	log_debug("found partition key (key=%s, partition_key=%s)", key.c_str(), s.c_str());

	return s;
}

int cluster::_get_proxy_thread(string node_key, int key_hash, shared_thread& t) {
	int thread_type = 0;
	pthread_rwlock_rdlock(&this->_mutex_node_map);
	if (this->_node_map.count(node_key) == 0) {
		pthread_rwlock_unlock(&this->_mutex_node_map);
		log_warning("no such node (node_key=%s)", node_key.c_str());
		return -1;
	}
	thread_type = this->_node_map[node_key].node_thread_type;
	pthread_rwlock_unlock(&this->_mutex_node_map);

	thread_pool::local_map m = this->_thread_pool->get_active(thread_type);
	if (static_cast<int>(m.size()) < this->_proxy_concurrency) {
		int i;
		for (i = 0; i < this->_proxy_concurrency - static_cast<int>(m.size()); i++) {
			shared_thread tmp = this->_thread_pool->get(thread_type);
			string node_server_name;
			int node_server_port = 0;
			this->from_node_key(node_key, node_server_name, node_server_port);
			handler_proxy* h = new handler_proxy(tmp, this, node_server_name, node_server_port);
			tmp->trigger(h, true, false);
		}
		m = this->_thread_pool->get_active(thread_type);
	}

	int index = key_hash % m.size();
	int i = 0;
	for (thread_pool::local_map::iterator it = m.begin(); it != m.end(); it++) {
		if (i == index) {
			t = it->second;
			return 0;
		}
		i++;
	}

	return -1;
}

shared_connection cluster::_open_index() {
	return this->_index_servers.size() > 1
		? this->_open_index_redundant()
		: this->_open_index_single_server();
}

/**
 * open index server with default connect_index_retry_limit count
 */
shared_connection cluster::_open_index_single_server() {
	index_server server = this->_index_servers.front();
	shared_connection_tcp ctp(new connection_tcp(server.index_server_name, server.index_server_port));
	if (ctp && ctp->open() == 0) {
		return ctp;
	}
	return shared_connection();
}

/**
 * open index server.
 * try to connect other server when failed once.
 */
shared_connection cluster::_open_index_redundant() {
	vector<index_server> servers = this->_index_servers;
	random_shuffle(servers.begin(), servers.end());
	for (vector<index_server>::iterator it = servers.begin(); it != servers.end(); it++) {
		shared_connection_tcp ctp(new connection_tcp(it->index_server_name, it->index_server_port));
		int connect_retry_limit = ctp->get_connect_retry_limit();
		ctp->set_connect_retry_limit(0);
		if (ctp && ctp->open() == 0) {
			ctp->set_connect_retry_limit(connect_retry_limit);
			return ctp;
		}
	}
	return shared_connection();
}

/**
 * return bwlimit divided by partition size
 */
int cluster::_get_reconstruction_bwlimit_for_new_partition(size_t current_partition_size) {
	int bwlimit = this->get_reconstruction_bwlimit();
	if (bwlimit <= 0 || current_partition_size <= 0) {
		return bwlimit;
	}

	// avoid 0 (= unlimited)
	return max(bwlimit / (int)current_partition_size, 1);
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
