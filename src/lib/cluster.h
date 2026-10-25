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
#include "source_eligibility.h"

using namespace std;

namespace gree {
namespace flare {

typedef class proxy_event_listener proxy_event_listener;

typedef boost::shared_ptr<proxy_event_listener> shared_proxy_event_listener;

typedef class op_proxy_write op_proxy_write;
typedef class op_proxy_read op_proxy_read;

typedef class queue_proxy_read queue_proxy_read;
typedef boost::shared_ptr<queue_proxy_read> shared_queue_proxy_read;

typedef class queue_proxy_write queue_proxy_write;
typedef boost::shared_ptr<queue_proxy_write> shared_queue_proxy_write;

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
		friend class boost::serialization::access;
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
	thread_pool*					_req_thread_pool;
	thread_pool*					_other_thread_pool;
	storage::hash_algorithm _key_hash_algorithm;
	const storage::hash_algorithm _proxy_hash_algorithm;
	key_resolver*					_key_resolver;
	storage*							_storage;
	type									_type;
	pthread_mutex_t				_mutex_serialization;

	int										_master_reconstruction;
	bool _boot_shift_pending;
	bool _reannounce_active;
	bool _activation_pending;
	pthread_mutex_t				_mutex_master_reconstruction;

	uint64_t							_node_map_version;
	pthread_mutex_t				_mutex_node_map_version;
	node_map							_node_map;
	node_partition_map		_node_partition_map;
	node_partition_map		_node_partition_prepare_map;
	pthread_rwlock_t			_mutex_node_map;
	pthread_rwlock_t			_mutex_node_partition_map;

	string								_node_key;
	// decision 2026-10-08: set when the map made this node a master while its
	// copy was in a forbidden state; it then serves no reads or writes as
	// that master (fail closed) until the map takes the role away
	volatile bool					_promotion_refused = false;
	string								_promotion_refused_why;
	// C' write authority: a refusal by the authority gate is NOT final. The shift that was refused is
	// kept here and run again (same checks, same gate) when the missing condition may have arrived: the
	// first-build allowance, the COMMITTED intent / quiet time, a grant. Cleared when the map moves.
	// Guarded by _mutex_node_map + _mutex_node_partition_map (every reader and writer holds both).
	// Two reasons, kept apart: retry_copy (the copy is forbidden as a master) and retry_authority (the
	// write authority gate said no). Either way the retry re-runs the WHOLE shift, both gates.
	enum promotion_retry_reason { retry_authority, retry_copy };
	bool									_promotion_retry_pending = false;
	promotion_retry_reason		_promotion_retry_reason = retry_authority;
	role									_promotion_retry_old_role = role_proxy;
	int										_promotion_retry_old_partition = -1;
	int										_promotion_retry_new_partition = -1;
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
	// how long startup_node keeps retrying the index server (K8s operator mode: a new
	// cluster's operator may still be waiting to lead); 0 = the connect retries only
	uint32_t								_index_startup_wait_ms;
	// startup_node only: the absolute startup deadline on CLOCK_MONOTONIC (ms; 0 = none). While it is set,
	// every connect attempt to an index server (single or redundant) is ONE attempt bounded by
	// min(1 s, time left), recomputed before each attempt; with no time left no attempt is made.
	uint64_t								_startup_deadline_ms;
	uint32_t								_startup_connect_attempts;		// connect attempts made under the deadline (tests)

	// [node]
	vector<index_server>	_index_servers;
	int										_proxy_concurrency;
	int										_reconstruction_interval;
	int										_reconstruction_bwlimit;
	bool									_repl_identity_forward;
	bool									_wal_follow_enabled;
	uint64_t								_wal_follow_max_batches;
	uint64_t								_wal_follow_max_bytes;
	int										_wal_follow_poll_interval_usec;
	int										_wal_follow_batch_delay_usec;
	shared_thread							_wal_follower_thread;
	// R3: the source this node's copy is eligible for (source_eligibility.h).
	// Lock order: the map locks (when held) BEFORE _mutex_read_source; the
	// binding lock is a leaf. Changed together with the map that invalidates
	// it, so no read decided under the new map can see the old eligibility.
	source_binding							_read_source;
	pthread_mutex_t							_mutex_read_source;
	pthread_cond_t							_cond_read_source;
	bool									_read_source_wake;
	shared_thread							_source_validator_thread;
	int										_source_check_interval_ms;
	string									_wal_follower_source;	// node key being followed
	replication						_replication_type;
	uint32_t							_proxy_prior_netmask;
	uint32_t							_max_total_thread_queue;
	bool								_read_unavailable_error;

	list<shared_proxy_event_listener>			_proxy_event_listeners;
	vector<shared_proxy_event_listener>		_fixed_proxy_event_listeners;

public:
	/** promotion's cursor reconciliation, from one typed read (see cluster.cc) */
	static int reconcile_cursor_on_promotion(storage* s, string& why);
	cluster(thread_pool* req_tp, thread_pool* other_tp, string server_name, int server_port);
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
	int run_boot_shift();
	/** re-run a promotion that the write authority gate refused (no-op when none is pending); called
	    periodically. The gate is evaluated again as for the first attempt: nothing is bypassed. */
	int retry_refused_promotion();
	/** the same re-run for a caller that must not wait behind the cluster locks (a long reconstruct):
	    when they are not both free within lock_wait_ms nothing is evaluated, *skipped is set and the
	    periodic retry decides later. */
	int retry_refused_promotion_bounded(int lock_wait_ms, bool* skipped);
	int _retry_refused_promotion(int lock_wait_ms, bool* skipped);
	// why a promotion refusal is being re-evaluated: "none", "copy" or "authority" (read under the locks)
	string get_promotion_retry_reason();
	void set_activation_pending(bool v) { this->_activation_pending = v; };
	int _run_boot_shift_locked();

	int set_storage(storage* st) { this->_storage = st; return 0; };

	int notify_master_reconstruction() { int n; pthread_mutex_lock(&this->_mutex_master_reconstruction); this->_master_reconstruction--; n = this->_master_reconstruction; pthread_mutex_unlock(&this->_mutex_master_reconstruction); return n; };
	int activate_node(bool skip_ready_state = false);
	int deactivate_node();
	int shutdown_node();
	int request_down_node(string node_server_name, int node_server_port);
	int request_up_node(string node_server_name, int node_server_port);
	int add_proxy_event_listener(shared_proxy_event_listener listener);
	proxy_request pre_proxy_read(op_proxy_read* op, storage::entry& e, void* parameter, shared_queue_proxy_read& q);
	// What this node is, for a write that pre_proxy_write let through
	// (proxy_request_continue), and for which partition: the write authority
	// (write_fence.h) is taken per partition and per role. replica: applied
	// because this node is a replica of `partition` (a proxied / forwarded
	// change); otherwise the master of `partition`. partition < 0: not set.
	struct write_role {
		write_role(): replica(false), partition(-1) { }
		bool	replica;
		int		partition;
	};
	proxy_request pre_proxy_write(op_proxy_write* op, shared_queue_proxy_write& q, uint64_t generic_value = 0, write_role* role = NULL);
	proxy_request post_proxy_write(op_proxy_write* op, bool sync = false);
	// TEST SEAM (FLARE_TEST_READ_TRACE_PREFIX): is `key` traced, and log the
	// ANSWER a traced read got (hit / miss / unavailable + why), on the same
	// connection identity as the decision line.
	static bool is_read_traced(const string& key);
	static void trace_read_result(op_proxy_read* o, const string& key, const char* result, const char* reason);

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
	int get_node_partition_map_size();
	// Node key of the partition's master in the CURRENT map (active map, else
	// the prepare map); "" when the partition has none. Read under the
	// partition-map lock; a reconstruction re-reads it every attempt.
	string get_partition_master_key(int partition);
	string get_own_node_key() { return this->_node_key; }
	bool is_promotion_refused() { return this->_promotion_refused; }
	string get_promotion_refused_why() { return this->_promotion_refused ? this->_promotion_refused_why : string(""); }
	// ---- R3: source eligibility of this node's copy ----------------------
	source_binding get_read_source();
	// a completed, validated copy (reconstruction activated it)
	void bind_read_source(const string& source, const string& master_id, const string& source_epoch, const string& reason);
	// no validated copy any more (a reconstruction started, or the role changed)
	void reset_read_source(const string& reason);
	storage* get_storage() { return this->_storage; }
	// the validator's decision, applied only if the binding is still the one
	// it judged (generation) and `current` is still the partition's master
	bool apply_source_decision(unsigned long long generation, const string& current, source_decision d, const string& reason);
	// own (role, state, partition) from the current map
	bool get_own_assignment(role& r, state& st, int& partition);
	// validator pacing: sleep until woken or `timeout_ms`
	void wait_source_check(int timeout_ms);
	void wake_source_validator();
	int get_source_check_interval_ms() { return this->_source_check_interval_ms; }
	int set_source_check_interval_ms(int ms) { this->_source_check_interval_ms = ms > 0 ? ms : 2000; return 0; }
	int start_source_validator();
	int set_proxy_concurrency(int proxy_concurrency) { this->_proxy_concurrency = proxy_concurrency; return 0; };
	int get_reconstruction_interval() { return this->_reconstruction_interval; };
	int set_reconstruction_interval(int reconstruction_interval) { this->_reconstruction_interval = reconstruction_interval; return 0; };
	int get_reconstruction_bwlimit() { return this->_reconstruction_bwlimit; };
	// SAF-10b stage 3: when set, a forwarded write carries the source's
	// replication identity ("rl=<epoch>/<label>") and the destination applies
	// it through the common rule instead of a plain local set. OFF by default:
	// a node that predates the tag would reject the request outright, so this
	// may only be turned on once every node in the cluster understands it.
	int set_repl_identity_forward(bool b) { this->_repl_identity_forward = b; return 0; };
	bool get_repl_identity_forward() { return this->_repl_identity_forward; };

	// CONTINUOUS REPLICATION lifecycle (SAF-10c). When enabled, a node that is
	// an ACTIVE SLAVE on a RocksDB backend runs one follower against its
	// partition's master, started and stopped from the node map: it is
	// (re)evaluated after every accepted map, and on every change of this
	// flag. OFF by default; the follower applies only through the common
	// rule, so it is safe to enable only once repl-identity-forward is on
	// cluster-wide as well.
	int set_wal_follow_enabled(bool b);
	bool get_wal_follow_enabled() { return this->_wal_follow_enabled; };
	int set_wal_follow_limits(uint64_t max_batches, uint64_t max_bytes, int poll_interval_usec,
			int batch_delay_usec = 0) {
		this->_wal_follow_max_batches = max_batches;
		this->_wal_follow_max_bytes = max_bytes;
		this->_wal_follow_poll_interval_usec = poll_interval_usec;
		this->_wal_follow_batch_delay_usec = batch_delay_usec;
		return 0;
	};
	// Stop the follower (shutdown path).
	int stop_wal_follower();
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
	bool is_read_unavailable_error() { return this->_read_unavailable_error; };
	void set_read_unavailable_error(bool b) { this->_read_unavailable_error = b; };

#ifdef ENABLE_MYSQL_REPLICATION
	int set_mysql_replication(bool mysql_replication) { this->_mysql_replication = mysql_replication; return 0; };
	bool is_mysql_replication() { return this->_mysql_replication; };
#endif
	int set_noreply_window_limit(int noreply_window_limit) { this->_noreply_window_limit = noreply_window_limit; return 0; };
	int set_index_startup_wait_ms(uint32_t ms) { this->_index_startup_wait_ms = ms; return 0; }
	uint32_t get_index_startup_wait_ms() { return this->_index_startup_wait_ms; }
	uint32_t get_startup_connect_attempts() { return this->_startup_connect_attempts; }
	/** startup_node's bounded wait for the index server: how long to sleep before the next attempt
	    after `elapsed_ms` of failed attempts with a budget of `wait_ms` (0 = give up now). */
	static uint32_t index_startup_retry_sleep_ms(uint64_t elapsed_ms, uint32_t wait_ms);
	/** the time left of the startup budget at `elapsed_ms` (0 when spent); with a budget of 0 there is no
	    deadline and the result is 0 too (callers check the budget first) */
	static uint32_t index_startup_remaining_ms(uint64_t elapsed_ms, uint32_t wait_ms);
	/** the bound of one connect attempt in the startup loop: at most 1 s, never past the deadline */
	static int index_startup_connect_timeout_ms(uint32_t remaining_ms);
	/** CLOCK_MONOTONIC in ms */
	static uint64_t monotonic_now_ms();
	/** the bound of the next connect attempt under the absolute deadline `deadline_ms` at `now_ms`
	    (0 = no time left: make no attempt) */
	static int startup_connect_bound_ms(uint64_t now_ms, uint64_t deadline_ms);
	/** whole milliseconds from `t0` to `t1` (CLOCK_MONOTONIC readings): each reading is normalized to
	    unsigned nanoseconds first, so a nanosecond borrow needs no signed arithmetic; 0 if `t1` is not
	    after `t0` (never a wrap to a huge value). */
	static uint64_t monotonic_elapsed_ms(const struct timespec& t0, const struct timespec& t1);
	/** Intervals (K8s operator builds). flared listens only after startup_node registered it, so until
	    then every TCP probe fails.
	    FROM ENTRY TO startup_node: everything up to the registration and the meta data exchange (each
	    connect attempt, the node add request and its whole reply, the meta reply, the sleeps) ends by ONE
	    absolute deadline `max_index_startup_wait_ms` after the entry; `index_connect_attempt_ms` is kept as
	    slack for the scheduling and the exit after the deadline.
	    FROM CONTAINER START: the process may spend `startup_pre_node_allowance_ms` before startup_node (an
	    ASSUMPTION, not measured: config, logging, thread pools; storage opens after startup_node), so it
	    listens at most `min_startup_probe_budget_ms` after the start. The startupProbe (helm chart and E2E
	    StatefulSet: tcpSocket on the flared port; liveness does not run before it succeeded) kills the
	    container at the earliest initialDelay + (failureThreshold - 1) x period after the start (the first
	    probe fires at initialDelay, the kill comes with the failureThreshold-th consecutive failure);
	    failureThreshold x period overstates it by one period. The chart refuses a startupProbe whose
	    earliest kill is below `min_startup_probe_budget_ms` (scripts/tests/test_helm_memory.py reads these
	    constants). The default (period 5 s, failureThreshold 18) kills at the earliest after 85 s. */
	static const uint32_t max_index_startup_wait_ms = 30000;
	static const uint32_t index_connect_attempt_ms = 2000;
	static const uint32_t startup_pre_node_allowance_ms = 20000;
	static const uint32_t min_startup_probe_budget_ms =
		max_index_startup_wait_ms + index_connect_attempt_ms + startup_pre_node_allowance_ms;
	static const uint32_t default_startup_probe_earliest_kill_ms = (18 - 1) * 5000;
	/** the configured wait as used: negative -> 0; in a K8s operator build at most
	    max_index_startup_wait_ms (a longer wait would be cut by the liveness kill anyway); `clamped`
	    tells whether the configured value was lowered. */
	static uint32_t effective_index_startup_wait_ms(int configured, bool k8s, bool& clamped);
	int get_noreply_window_limit() { return this->_noreply_window_limit; }

	inline string to_node_key(string server_name, int server_port) {
		string node_key = server_name + ":" + boost::lexical_cast<string>(server_port);
		return node_key;
	};

	inline int from_node_key(string node_key, string& server_name, int& server_port) {
		string::size_type n = node_key.find(":", 0);
		if (n == string::npos) {
			return -1;
		}
		server_name = node_key.substr(0, n);
		try {
			server_port = boost::lexical_cast<int>(node_key.substr(n+1));
		} catch (boost::bad_lexical_cast e) {
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
	// restore provenance: the binding the accepted map gives this node in
	// `partition`, count informational ("v1 partition=.. partitions=.. size=.. hash=.. resolver=..
	// hint=.. virtual=.."); assumes the partition map is locked
	string _partition_binding_for(int partition);
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
	// TEST SEAM (E2E only): with FLARE_TEST_READ_TRACE_PREFIX set, one log
	// line per read of a key with that prefix, recording what this process
	// based the local-or-proxy decision on. Unset (the default): no effect.
	void _trace_read(const string& key, const string& conn, const string& via, const char* decision, const string& reason, const partition& p, int partition_index, const string& target, const string& follow);
	// Start/stop/restart the follower to match this node's role in the
	// current maps. Assumes node_map and node_partition_map are locked by the
	// caller (it only reads them).
	int _reconcile_wal_follower_locked();
	// R3: called with the map write locks held, right after a map is installed
	void _check_read_source_locked(uint64_t node_map_version);
	bool _is_local_proxy_request(op_proxy_write* op);
	string _get_partition_key(string key);
	// t_id: the thread's id (map key) in the copy it was found in; pass it to
	// thread::enqueue so a thread reused since then refuses the item
	int _get_proxy_thread(string node_key, int key_hash, shared_thread& t, unsigned int& t_id);
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
