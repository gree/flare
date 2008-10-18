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
#include "handler_monitor.h"
#include "op_node_add.h"
#include "queue_node_sync.h"
#include "queue_update_monitor_interval.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for cluster
 */
cluster::cluster(thread_pool* tp, string data_dir, string server_name, int server_port):
		_thread_pool(tp),
		_data_dir(data_dir),
		_server_name(server_name),
		_server_port(server_port),
		_monitor_interval(0),
		_thread_type(default_thread_type),
		_index_server_name(""),
		_index_server_port(0) {
	this->_node_key = this->to_node_key(server_name, server_port);
	pthread_mutex_init(&this->_mutex_serialization, NULL);
	pthread_rwlock_init(&this->_mutex_node_map, NULL);
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
		log_warning("bad digit [%s]", e.what());
		return -1;
	}

	return 0;
}

/**
 *	startup proc for index process
 */
int cluster::startup_index() {
	this->_type = type_index;

	// load
	if (this->_load() < 0) {
		log_err("failed to load serialized vars", 0);
		return -1;
	}
	if (this->reconstruct_node(this->get_node_info()) < 0) {
		log_err("failed to reconstruct node map", 0);
		return -1;
	}

	// monitoring threads
	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		shared_thread t = this->_thread_pool->get(it->second.node_thread_type);
		handler_monitor* h = _new_ handler_monitor(t, this, it->second.node_server_name, it->second.node_server_port);
		h->set_monitor_interval(this->_monitor_interval);
		t->trigger(h);
	}

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

	shared_connection c(new connection());
	if (c->open(this->_index_server_name, this->_index_server_port) < 0) {
		log_err("failed to connect to index server", 0);
		return -1;
	}

	op_node_add* p = _new_ op_node_add(c, this);
	vector<node> v;
	if (p->run_client(v) < 0) {
		log_err("failed to add node to index server", 0);
		_delete_(p);
		return -1;
	}
	
	// set state and other nodes
	if (this->reconstruct_node(v) < 0) {
		log_err("failed to reconstruct node map", 0);
		_delete_(p);
		return -1;
	}
	
	_delete_(p);

	return 0;
}

/**
 *	reconstruct all node map
 */
int cluster::reconstruct_node(vector<node> v) {
	pthread_rwlock_wrlock(&this->_mutex_node_map);
	pthread_rwlock_wrlock(&this->_mutex_node_partition_map);

	log_notice("reconstructing node map and node partition map... (%d entries)", v.size());

	node_map nm;
	node_partition_map npm;
	node_partition_map nppm;

	for (vector<node>::iterator it = v.begin(); it != v.end(); it++) {
		string node_key = this->to_node_key(it->node_server_name, it->node_server_port);
		log_debug("node_key: %s%s", node_key.c_str(), node_key == this->_node_key ? " (myself)" : "");

		if (this->_node_map.count(node_key) == 0) {
			log_debug("-> new node", 0);
		} else {
			log_debug("-> existing node", 0);
			if (node_key == this->_node_key) {
				// myself
				if (it->node_role != this->_node_map[node_key].node_role) {
					log_notice("update: node_role (%d -> %d)", it->node_role, this->_node_map[node_key].node_role);
				}
				if (it->node_state != this->_node_map[node_key].node_state) {
					log_notice("update: node_state (%d -> %d)", it->node_state, this->_node_map[node_key].node_state);
				}
				if (it->node_partition != this->_node_map[node_key].node_partition) {
					log_notice("update: node_partition (%d -> %d)", it->node_partition, this->_node_map[node_key].node_partition);
				}
				if (it->node_balance != this->_node_map[node_key].node_balance) {
					log_notice("update: node_balance (%d -> %d)", it->node_balance, this->_node_map[node_key].node_balance);
				}
				if (it->node_thread_type != this->_node_map[node_key].node_thread_type) {
					// this should not happen
					log_warning("update: node_thread_type (%d -> %d)", it->node_thread_type, this->_node_map[node_key].node_thread_type);
				}
			}
			this->_node_map.erase(node_key);
		}
		nm[node_key] = *it;

		// node parition map (master)
		try {
			if (it->node_role == role_master) {
				if (it->node_partition < 0) {
					throw "node partition is inconsistent";
				}

				if (it->node_state == state_active) {
					if (npm[it->node_partition].master.node_key.empty() == false) {
						throw "master is already set, cannot overwrite";
					}
					npm[it->node_partition].master.node_key = node_key;
					npm[it->node_partition].master.node_balance = it->node_balance;
				} else if (it->node_state == state_prepare) {
					if (nppm[it->node_partition].master.node_key.empty() == false) {
						throw "master (prepare) is already set, cannot overwrite";
					}
					nppm[it->node_partition].master.node_key = node_key;
					nppm[it->node_partition].master.node_balance = it->node_balance;
				}
			}
		} catch (string e) {
			log_err("%s [node_key=%s, state=%d, role=%d, partition=%d]", e.c_str(), node_key.c_str(), it->node_state, it->node_role, it->node_partition);
		}
	}

	// node partition map (slave)
	for (vector<node>::iterator it = v.begin(); it != v.end(); it++) {
		if (it->node_role != role_slave || it->node_state == state_down) {
			continue;
		}

		string node_key = this->to_node_key(it->node_server_name, it->node_server_port);
		try {
			if (it->node_partition < 0) {
				throw "node partition is inconsistent";
			}

			if (it->node_state == state_active) {
				if (npm.count(it->node_partition) == 0) {
					throw "no active master for this slave";
				}
				
				partition_node pn;
				pn.node_key = node_key;
				pn.node_balance = it->node_balance;
				npm[it->node_partition].slave.push_back(pn);
			} else if (it->node_state == state_prepare) {
				if (npm.count(it->node_partition) == 0 && nppm.count(it->node_partition) == 0) {
					throw "no active or prepare master for this slave";
				}

				partition_node pn;
				pn.node_key = node_key;
				pn.node_balance = it->node_balance;
				if (npm.count(it->node_partition) > 0) {
					npm[it->node_partition].slave.push_back(pn);
				} else {
					nppm[it->node_partition].slave.push_back(pn);
				}
			}
		} catch (string e) {
			log_err("%s [node_key=%s, state=%d, role=%d, partition=%d]", e.c_str(), node_key.c_str(), it->node_state, it->node_role, it->node_partition);
		}
	}

	// check out removed nodes
	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		log_debug("detecting removed node [node_key=%s]", it->first.c_str());
		this->_node_map.erase(it->first);
	}

	// check and log node partition map consistency
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
		log_err("possibly missing partition (parition=%d, size=%d)", n, npm.size());
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		pthread_rwlock_unlock(&this->_mutex_node_map);
		return -1;
	}

	n = 0;
	log_notice("node partition map (prepare):", 0);
	if (nppm.size() > 1) {
		log_err("more than 1 partition prepare map -> some thing is seriously going wrong", 0);
		pthread_rwlock_unlock(&this->_mutex_node_partition_map);
		pthread_rwlock_unlock(&this->_mutex_node_map);
		return -1;
	}

	for (node_partition_map::iterator it = nppm.begin(); it != nppm.end(); it++) {
		if (it->first != static_cast<int>(npm.size())) {
			log_err("invalid partition [%d] for partition prepare map -> some thing is seriously going wrong", it->first);
			pthread_rwlock_unlock(&this->_mutex_node_partition_map);
			pthread_rwlock_unlock(&this->_mutex_node_map);
			return -1;
		}
		log_notice("%d(prepare): master (node_key=%s, node_balance=%d)", it->first, it->second.master.node_key.c_str(), it->second.master.node_balance);

		int m = 0;
		for (vector<partition_node>::iterator it_slave = it->second.slave.begin(); it_slave != it->second.slave.end(); it_slave++) {
			log_notice("%d(prepare): slave[%d] (node_key=%s, node_balance=%d)", it->first, m, it_slave->node_key.c_str(), it_slave->node_balance);
			m++;
		}
	}

	this->_node_map = nm;
	this->_node_partition_map = npm;
	this->_node_partition_prepare_map = nppm;

	pthread_rwlock_unlock(&this->_mutex_node_partition_map);
	pthread_rwlock_unlock(&this->_mutex_node_map);

	return 0;
}

/**
 *	get node info vector
 */
vector<cluster::node> cluster::get_node_info() {
	vector<node> v;

	pthread_rwlock_rdlock(&this->_mutex_node_map);
	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		v.push_back(it->second);
	}
	pthread_rwlock_unlock(&this->_mutex_node_map);

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

	string node_key = this->to_node_key(node_server_name, node_server_port);
	log_debug("adding new node (server_name=%s, server_port=%d, node_key=%s)", node_server_name.c_str(), node_server_port, node_key.c_str());

	// add node to map
	pthread_rwlock_wrlock(&this->_mutex_node_map);
	int thread_type;
	bool replace = false;
	try {
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

		log_debug("node is [%s] added to node map (state=%d, thread_type=%d)", node_key.c_str(), n.node_state, n.node_thread_type);
	} catch (int e) {
		pthread_rwlock_unlock(&this->_mutex_node_map);
		return e;
	}

	this->_save();
	pthread_rwlock_unlock(&this->_mutex_node_map);

	// create monitoring thread
	if (replace == false) {
		shared_thread t = this->_thread_pool->get(thread_type);
		handler_monitor* h = _new_ handler_monitor(t, this, node_server_name, node_server_port);
		h->set_monitor_interval(this->_monitor_interval);
		t->trigger(h);
	}

	// notify other nodes
	shared_queue_node_sync q(new queue_node_sync(this));
	this->_broadcast(q);
	
	return 0;
}

/**
 *	[index] node down event handler
 */
int cluster::down_node(string node_server_name, int node_server_port) {
	return 0;
}

/**
 *	[index] set node server monitoring interval
 */
int cluster::set_monitor_interval(int monitor_interval) {
	this->_monitor_interval = monitor_interval;

	// notify to current threads
	shared_queue_update_monitor_interval q(new queue_update_monitor_interval(this->_monitor_interval));
	this->_broadcast(q, true);

	return 0;
}
// }}}

// {{{ protected methods
/**
 *	broadcast thread_queue to all node servers
 *	
 *	[notice] all threads receive same thread_queue object
 */
int cluster::_broadcast(shared_thread_queue q, bool sync) {
	log_debug("broadcasting queue [ident=%s]", q->get_ident().c_str());

	pthread_rwlock_rdlock(&this->_mutex_node_map);
	for (node_map::iterator it = this->_node_map.begin(); it != this->_node_map.end(); it++) {
		thread_pool::local_map m = this->_thread_pool->get_active(it->second.node_thread_type);
		for (thread_pool::local_map::iterator it_local = m.begin(); it_local != m.end(); it_local++) {
			if (it_local->second->enqueue(q) < 0) {
				log_warning("enqueue failed (perhaps thread is now exiting?)", 0);
				continue;
			}
			if (sync) {
				q->sync_ref();
			}
			log_debug("  -> enqueue (id=%d)", it_local->first);
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
 */
int cluster::_save() {
	string path = this->_data_dir + "/cluster_node.txt";
	string path_tmp = path + ".tmp";

	pthread_mutex_lock(&this->_mutex_serialization);
	ofstream ofs(path_tmp.c_str());
	if (ofs.fail()) {
		log_err("creating serialization file failed -> daemon restart will cause serious problem (path=%s)", path_tmp.c_str());
		pthread_mutex_unlock(&this->_mutex_serialization);
		return -1;
	}

	archive::text_oarchive oa(ofs);
	oa << (const node_map&)this->_node_map;
	oa << (const int&)this->_thread_type;

	ofs.close();

	if (unlink(path.c_str()) < 0 && errno != ENOENT) {
		pthread_mutex_unlock(&this->_mutex_serialization);
		log_err("unlink() for current serialization file failed (%s)", util::strerror(errno));
		return -1;
	}
	if (rename(path_tmp.c_str(), path.c_str()) < 0) {
		pthread_mutex_unlock(&this->_mutex_serialization);
		log_err("rename() for current serialization file failed (%s)", util::strerror(errno));
		return -1;
	}
	pthread_mutex_unlock(&this->_mutex_serialization);

	return 0;
}

/**
 *	load node variables
 */
int cluster::_load() {
	string path = this->_data_dir + "/cluster_node.txt";

	pthread_mutex_lock(&this->_mutex_serialization);
	ifstream ifs(path.c_str());
	if (ifs.fail()) {
		pthread_mutex_unlock(&this->_mutex_serialization);
		struct stat st;
		if (::stat(path.c_str(), &st) < 0 && errno == ENOENT) {
			log_info("no such entry -> skip unserialization [%s]", path.c_str());
			return 0;
		} else {
			log_err("opening serialization file failed -> daemon restart will cause serious problem (path=%s)", path.c_str());
		}
		return -1;
	}

	archive::text_iarchive ia(ifs);
	ia >> this->_node_map;
	ia >> this->_thread_type;

	ifs.close();
	pthread_mutex_unlock(&this->_mutex_serialization);

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
