/**
 *	op_node_remove.cc
 *
 *	implementation of gree::flare::op_node_remove
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_node_remove.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_node_remove
 */
op_node_remove::op_node_remove(shared_connection c, cluster* cl):
		op(c, "node_remove"),
		_cluster(cl),
		_node_server_name(""),
		_node_server_port(0) {
		
}

/**
 *	dtor for op_node_remove
 */
op_node_remove::~op_node_remove() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_node_remove::run_client(string node_server_name, int node_server_port) {
	if (this->_run_client(node_server_name, node_server_port) < 0) {
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
 *	NODE ROLE [node_server_name] [node_server_port]
 */
int op_node_remove::_parse_text_server_parameters() {
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

int op_node_remove::_run_server() {
	if (this->_cluster->remove_node(this->_node_server_name, this->_node_server_port) < 0) {
		this->_send_result(result_server_error, "failed to remove node");
		return -1;
	}

	return this->_send_result(result_ok);
}

int op_node_remove::_run_client(string node_server_name, int node_server_port) {
	log_err("not yet implemented :(", 0);

	return 0;
}

int op_node_remove::_parse_text_client_parameters() {
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
