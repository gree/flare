/**
 *	op_stats.cc
 *
 *	implementation of gree::flare::op_stats
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "op_stats.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_stats
 */
op_stats::op_stats(shared_connection c):
		op(c, "stats"),
		_stats_type(stats_type_default) {
}

/**
 *	dtor for op_stats
 */
op_stats::~op_stats() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_stats::_parse_server_parameter() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (q[0] == '\0') {
		this->_stats_type = stats_type_default;
	} else if (strcmp(q, "items") == 0) {
		this->_stats_type = stats_type_items;
	} else if (strcmp(q, "slabs") == 0) {
		this->_stats_type = stats_type_slabs;
	} else if (strcmp(q, "sizes") == 0) {
		this->_stats_type = stats_type_sizes;
	} else if (strcmp(q, "threads") == 0) {
		char r[BUFSIZ];
		util::next_word(p+n, r, sizeof(r));
		if (r[0] == '\0') {
			this->_stats_type = stats_type_threads;
		} else if (strcmp(r, "request") == 0) {
			this->_stats_type = stats_type_threads_request;
		} else {
			this->_stats_type = stats_type_error;
		}
	} else if (strcmp(q, "nodes") == 0) {
		this->_stats_type = stats_type_nodes;
	} else {
		this->_stats_type = stats_type_error;
	}
	log_debug("parameter=%s -> stats_type=%d", p, this->_stats_type);
	_delete_(p);

	if (this->_stats_type == stats_type_error) {
		return -1;
	}

	return 0;
}

int op_stats::_run_server() {
	return 0;
}

int op_stats::_send_stats(thread_pool* tp) {
	ostringstream s;

	rusage usage = stats_object->get_rusage();
	char usage_user[BUFSIZ];
	char usage_system[BUFSIZ];
	snprintf(usage_user, sizeof(usage_user), "%ld.%06d", usage.ru_utime.tv_sec, static_cast<int>(usage.ru_utime.tv_usec));
	snprintf(usage_system, sizeof(usage_user), "%ld.%06d", usage.ru_stime.tv_sec, static_cast<int>(usage.ru_stime.tv_usec));

	s << "STAT " << "pid " << stats_object->get_pid() << line_delimiter;
	s << "STAT " << "uptime " << stats_object->get_uptime() << line_delimiter;
	s << "STAT " << "time " << stats_object->get_timestamp() << line_delimiter;
	s << "STAT " << "version " << stats_object->get_version() << line_delimiter;
	s << "STAT " << "pointer_size " << stats_object->get_pointer_size() << line_delimiter;
	s << "STAT " << "rusage_user " << usage_user << line_delimiter;
	s << "STAT " << "rusage_system " << usage_system << line_delimiter;
	s << "STAT " << "curr_items " << stats_object->get_curr_items() << line_delimiter;
	s << "STAT " << "total_items " << stats_object->get_bytes() << line_delimiter;
	s << "STAT " << "bytes " << stats_object->get_total_items() << line_delimiter;
	s << "STAT " << "curr_connections " << stats_object->get_curr_connections(tp) << line_delimiter;
	s << "STAT " << "total_connections " << stats_object->get_total_connections() << line_delimiter;
	s << "STAT " << "connection_structures " << stats_object->get_connection_structures() << line_delimiter;
	s << "STAT " << "cmd_get " << stats_object->get_cmd_get() << line_delimiter;
	s << "STAT " << "cmd_set " << stats_object->get_cmd_set() << line_delimiter;
	s << "STAT " << "get_hits " << stats_object->get_hits() << line_delimiter;
	s << "STAT " << "get_misses " << stats_object->get_misses() << line_delimiter;
	s << "STAT " << "evictions " << stats_object->get_evictions() << line_delimiter;
	s << "STAT " << "bytes_read " << stats_object->get_bytes_read() << line_delimiter;
	s << "STAT " << "bytes_written " << stats_object->get_bytes_written() << line_delimiter;
	s << "STAT " << "limit_maxbytes " << stats_object->get_limit_maxbytes() << line_delimiter;
	s << "STAT " << "threads " << stats_object->get_threads(tp) << line_delimiter;
	s << "STAT " << "pool_threads " << stats_object->get_pool_threads(tp);

	this->_connection->writeline(s.str().c_str());

	return 0;
}

int op_stats::_send_stats_items() {
	return 0;
}

int op_stats::_send_stats_slabs() {
	return 0;
}

int op_stats::_send_stats_sizes() {
	return 0;
}

int op_stats::_send_stats_threads(thread_pool* tp) {
	ostringstream s;

	vector<thread::thread_info> list = tp->get_thread_info();
	for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
		s << "STAT " << it->id << ":type " << it->type << line_delimiter;
		s << "STAT " << it->id << ":peer " << it->peer_name << ":" << it->peer_port << line_delimiter;
		s << "STAT " << it->id << ":op " << it->op << line_delimiter;
		s << "STAT " << it->id << ":uptime " << (time(NULL) - it->timestamp) << line_delimiter;
		s << "STAT " << it->id << ":state " << it->state << line_delimiter;
		s << "STAT " << it->id << ":info " << it->info << line_delimiter;
	}
	this->_connection->write(s.str().c_str(), s.str().size());
	
	return 0;
}

int op_stats::_send_stats_threads(thread_pool* tp, int type) {
	ostringstream s;

	vector<thread::thread_info> list = tp->get_thread_info(type);
	for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
		s << "STAT " << it->id << ":type " << it->type << line_delimiter;
		s << "STAT " << it->id << ":peer " << it->peer_name << ":" << it->peer_port << line_delimiter;
		s << "STAT " << it->id << ":op " << it->op << line_delimiter;
		s << "STAT " << it->id << ":uptime " << (time(NULL) - it->timestamp) << line_delimiter;
		s << "STAT " << it->id << ":state " << it->state << line_delimiter;
		s << "STAT " << it->id << ":info " << it->info << line_delimiter;
	}
	this->_connection->write(s.str().c_str(), s.str().size());
	
	return 0;
}

int op_stats::_send_stats_nodes(cluster* cl) {
	ostringstream s;

	vector<cluster::node> v = cl->get_node_info();
	for (vector<cluster::node>::iterator it = v.begin(); it != v.end(); it++) {
		string node_key = cl->to_node_key(it->node_server_name, it->node_server_port);
		s << "STAT " << node_key << ":role " << it->node_role << line_delimiter;
		s << "STAT " << node_key << ":state " << it->node_state << line_delimiter;
		s << "STAT " << node_key << ":parition " << it->node_partition << line_delimiter;
		s << "STAT " << node_key << ":balance " << it->node_balance << line_delimiter;
		s << "STAT " << node_key << ":thread_type " << it->node_thread_type << line_delimiter;
	}
	this->_connection->write(s.str().c_str(), s.str().size());

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
