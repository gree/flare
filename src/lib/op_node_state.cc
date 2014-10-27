/**
 *	op_node_state.cc
 *
 *	implementation of gree::flare::op_node_state
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_node_state.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_node_state
 */
op_node_state::op_node_state(shared_connection c, cluster* cl):
		op(c, "node_state"),
		_cluster(cl),
		_node_server_name(""),
		_node_server_port(0),
		_node_state(cluster::state_active) {
}

/**
 *	dtor for op_node_state
 */
op_node_state::~op_node_state() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_node_state::run_client(string node_server_name, int node_server_port, cluster::state node_state) {
	if (this->_run_client(node_server_name, node_server_port, node_state) < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters();
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 *
 *	syntax:
 *	NODE ROLE [node_server_name] [node_server_port] [node_state]
 */
int op_node_state::_parse_text_server_parameters() {
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

		// node state
		n += util::next_word(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no node state found", 0);
			throw -1;
		}
		cluster::state s = cluster::state_active;
		if (cluster::state_cast(q, s) < 0) {
			log_debug("unknown state [%s] (cast failed)", q);
			throw -1;
		}
		this->_node_state = s;
		log_debug("storing node state [%s -> %d]", q, s);

		n += util::next_word(p+n, q, sizeof(q));
		if (q[0]) {
			// no more arguments allowed
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

int op_node_state::_run_server() {
	if (this->_cluster->set_node_state(this->_node_server_name, this->_node_server_port, this->_node_state) < 0) {
		this->_send_result(result_server_error, "failed to set state");
		return -1;
	}

	return this->_send_result(result_ok);
}

int op_node_state::_run_client(string node_server_name, int node_server_port, cluster::state node_state) {
	char request[BUFSIZ];
	snprintf(request, sizeof(request), "node state %s %d %s", node_server_name.c_str(), node_server_port, cluster::state_cast(node_state).c_str());

	return this->_send_request(request);
}

int op_node_state::_parse_text_client_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	if (this->_parse_text_response(p, this->_result, this->_result_message) < 0) {
		delete[] p;
		return -1;
	}
	delete[] p;

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
