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
op_node_add::op_node_add(shared_connection c, cluster* p):
		op(c, "node_add"),
		_cluster(p),
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
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 *
 *	syntax:
 *	NODE ADD [node name(required)] [node port(required)]
 */
int op_node_add::_parse_server_parameter() {
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
			this->_node_server_port = lexical_cast<int>(q);
			log_debug("storing node server port [%d]", this->_node_server_port);
		} catch (bad_lexical_cast e) {
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
		_delete_(p);
		return e;
	}

	_delete_(p);

	return 0;
}

int op_node_add::_run_server() {
	if (this->_cluster->add_node(this->_node_server_name, this->_node_server_port) < 0) {
		this->_send_error(error_type_server, "failed to add node");
		return -1;
	}

	// get updated node info and tell it to new node

	return this->_send_end();
}

int op_node_add::_run_client() {
	char request[BUFSIZ];
	snprintf(request, sizeof(request), "node add %s %d", this->_cluster->get_server_name().c_str(), this->_cluster->get_server_port());
	return this->_send_request(request);
}

int op_node_add::_parse_client_parameter() {
	return 0;
}
// }}}

// {{{ private methods
// }}}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
