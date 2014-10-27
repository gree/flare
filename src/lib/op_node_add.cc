/**
 *	op_node_add.cc
 *
 *	implementation of gree::flare::op_node_add
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_node_add.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_node_add
 */
op_node_add::op_node_add(shared_connection c, cluster* cl):
		op(c, "node_add"),
		_cluster(cl),
		_node_server_name(""),
		_node_server_port(0) {
}

/**
 *	dtor for op_node_add
 */
op_node_add::~op_node_add() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_node_add::run_client(vector<cluster::node>& v) {
	if (this->_run_client() < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters(v);
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 *
 *	syntax:
 *	NODE ADD [node name(required)] [node port(required)]
 */
int op_node_add::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[1024];
	try {
		// node server name
		int n = util::next_word(p, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no node server name found", 0);
			throw -1;
		}
		this->_node_server_name = q;
		log_debug("storing node server name [%s]", this->_node_server_name.c_str());

		// node server port
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no node server port found", 0);
			throw -1;
		}
		try {
			this->_node_server_port = boost::lexical_cast<int>(q);
			log_debug("storing node server port [%d]", this->_node_server_port);
		} catch (boost::bad_lexical_cast e) {
			log_debug("invalid node server port (port=%s)", q);
			throw -1;
		}

		// no extra parameter allowed
		util::next_word(p+n, q, sizeof(q));
		if (q[0]) {
			log_debug("bogus string(s) found [%s] -> error", q);
			throw -1;
		}
	} catch (int e) {
		delete[] p;
		return e;
	}

	delete[] p;

	return 0;
}

int op_node_add::_run_server() {
	if (this->_cluster->add_node(this->_node_server_name, this->_node_server_port) < 0) {
		this->_send_result(result_server_error, "failed to add node");
		return -1;
	}

	vector<cluster::node> v = this->_cluster->get_node();
	
	ostringstream s;
	for (vector<cluster::node>::iterator it = v.begin(); it != v.end(); it++) {
		char buf[BUFSIZ];
		snprintf(buf, sizeof(buf), "NODE %s %d %d %d %d %d %d", it->node_server_name.c_str(), it->node_server_port, it->node_role, it->node_state, it->node_partition, it->node_balance, it->node_thread_type);
		s << buf << line_delimiter;
	}
	this->_connection->write(s.str().c_str(), s.str().size());

	return this->_send_result(result_end);
}

int op_node_add::_run_client() {
	char request[BUFSIZ];
	string server_name = this->_cluster->get_server_name();
	snprintf(request, sizeof(request), "node add %s %d", server_name.c_str(), this->_cluster->get_server_port());
	return this->_send_request(request);
}

int op_node_add::_parse_text_client_parameters(vector<cluster::node>& v) {
	v.clear();

	for (;;) {
		char* p;
		if (this->_connection->readline(&p) < 0) {
			log_err("something is going wrong while node add request", 0);
			return -1;
		}
		if (strcmp(p, "END\n") == 0) {
			delete[] p;
			break;
		}

		cluster::node n;
		if (n.parse(p) < 0) {
			delete[] p;
			return -1;
		}

		log_debug("node: server_name[%s] server_port[%d] role[%d] state[%d] partition[%d] balance[%d] thread_type[%d]", n.node_server_name.c_str(), n.node_server_port, n.node_role, n.node_state, n.node_partition, n.node_balance, n.node_thread_type);
		v.push_back(n);

		delete[] p;
	}

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
