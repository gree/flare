/**
 *	op_node_role.cc
 *
 *	implementation of gree::flare::op_node_role
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_node_role.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_node_role
 */
op_node_role::op_node_role(shared_connection c, cluster* cl):
		op(c, "node_role"),
		_cluster(cl),
		_node_server_name(""),
		_node_server_port(0),
		_node_role(cluster::role_proxy),
		_node_balance(-1),
		_node_partition(-1) {
}

/**
 *	dtor for op_node_role
 */
op_node_role::~op_node_role() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_node_role::run_client(string node_server_name, int node_server_port, cluster::role node_role, int node_balance, int node_partition) {
	if (this->_run_client(node_server_name, node_server_port, node_role, node_balance, node_partition) < 0) {
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
 *	NODE ROLE [node_server_name] [node_server_port] [node_role] ([node_balance])
 */
int op_node_role::_parse_text_server_parameters() {
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

		// node role
		n += util::next_word(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no node role found", 0);
			throw -1;
		}
		cluster::role r = cluster::role_proxy;
		if (cluster::role_cast(q, r) < 0) {
			log_debug("unknown role [%s] (cast failed)", q);
			throw -1;
		}
		this->_node_role = r;
		log_debug("storing node role [%s -> %d]", q, r);

		// node balance (if we have)
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0]) {
			try {
				this->_node_balance = boost::lexical_cast<int>(q);
				log_debug("storing node balance [%d]", this->_node_balance);
			} catch (boost::bad_lexical_cast e) {
				log_debug("invalid node balance (balance=%s)", q);
				throw -1;
			}
		}

		// node partition (if we have)
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0]) {
			try {
				this->_node_partition = boost::lexical_cast<int>(q);
				log_debug("storing node partition [%d]", this->_node_partition);
			} catch (boost::bad_lexical_cast e) {
				log_debug("invalid node partition (partition=%s)", q);
				throw -1;
			}
		}
	} catch (int e) {
		delete[] p;
		return e;
	}

	delete[] p;

	return 0;
}

int op_node_role::_run_server() {
	if (this->_cluster->set_node_role(this->_node_server_name, this->_node_server_port, this->_node_role, this->_node_balance, this->_node_partition) < 0) {
		this->_send_result(result_server_error, "failed to set role (and balance)");
		return -1;
	}

	return this->_send_result(result_ok);
}

int op_node_role::_run_client(string node_server_name, int node_server_port, cluster::role node_role, int node_balance, int node_partition) {
	char request[BUFSIZ];
	snprintf(request, sizeof(request), "node role %s %d %s %d %d", node_server_name.c_str(), node_server_port, cluster::role_cast(node_role).c_str(), node_balance, node_partition);

	return this->_send_request(request);

	return 0;
}

int op_node_role::_parse_text_client_parameters() {
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
