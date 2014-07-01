/**
 *	op_node_sync.cc
 *
 *	implementation of gree::flare::op_node_sync
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
// include order is important to include inttypes.h with __STDC_FORMAT_MACROS defined
#define __STDC_FORMAT_MACROS
#include <inttypes.h>

#include "op_node_sync.h"


namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_node_sync
 */
op_node_sync::op_node_sync(shared_connection c, cluster* cl):
		op(c, "node_sync"),
		_cluster(cl),
		_node_map_version(0) {
}

/**
 *	dtor for op_node_sync
 */
op_node_sync::~op_node_sync() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_node_sync::run_client(vector<cluster::node>& v, uint64_t node_map_version) {
	if (this->_run_client(v, node_map_version) < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters();
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_node_sync::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[1024];
	try {
		// node_map_version (optional)
		int n = util::next_digit(p, q, sizeof(q));
		if (q[0]) {
			try {
				this->_node_map_version = lexical_cast<uint64_t>(q);
				log_debug("storing node_map_version [%d]", this->_node_map_version);
			} catch (bad_lexical_cast e) {
				log_debug("invalid node_map_version (node_map_version=%s)", q);
				throw -1;
			}
		}

		// no more arguments allowed
		n += util::next_word(p+n, q, sizeof(q));
		if (q[0]) {
			log_debug("bogus string(s) found [%s] -> error", q); 
			throw -1;
		}
	} catch(int e) {
		delete[] p;
		return e;
	}

	delete[] p;

	return 0;
}

int op_node_sync::_run_server() {
	vector<cluster::node> v;

	for (;;) {
		char* p;
		if (this->_connection->readline(&p) < 0) {
			log_err("something is going wrong while node sync request", 0);
			this->_send_result(result_client_error, "format error");
			return -1;
		}

		if (strcmp(p, "END\n") == 0) {
			delete[] p;
			break;
		}

		cluster::node n;
		if (n.parse(p) < 0) {
			this->_send_result(result_client_error, "format error");
			delete[] p;
			return -1;
		}

		log_debug("node: server_name[%s] server_port[%d] role[%d] state[%d] partition[%d] balance[%d] thread_type[%d]", n.node_server_name.c_str(), n.node_server_port, n.node_role, n.node_state, n.node_partition, n.node_balance, n.node_thread_type);
		v.push_back(n);

		delete[] p;
	}

	if (this->_cluster->reconstruct_node(v, this->_node_map_version) < 0) {
		this->_send_result(result_server_error, "node sync error");
		return -1;
	}

	return this->_send_result(result_ok);
}

int op_node_sync::_run_client(vector<cluster::node>& v, uint64_t node_map_version) {
	char request[BUFSIZ];
	snprintf(request, sizeof(request), "node sync %" PRIu64, node_map_version);
	if (this->_send_request(request) < 0) {
		return -1;
	}

	ostringstream s;
	for (vector<cluster::node>::iterator it = v.begin(); it != v.end(); it++) {
		char buf[BUFSIZ];
		snprintf(buf, sizeof(buf), "NODE %s %d %d %d %d %d %d", it->node_server_name.c_str(), it->node_server_port, it->node_role, it->node_state, it->node_partition, it->node_balance, it->node_thread_type);
		s << buf << line_delimiter;
	}
	this->_connection->write(s.str().c_str(), s.str().size());

	return this->_send_result(result_end);
}

int op_node_sync::_parse_text_client_parameters() {
	char *p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	int r = (strcmp(p, "OK\n") == 0) ? 0 : -1;
	delete[] p;

	return r;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
