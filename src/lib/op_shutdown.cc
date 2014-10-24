/**
 *	op_shutdown.cc
 *
 *	implementation of gree::flare::op_shutdown
 *
 *	@author	Takanori Sejima <takanori.sejima@gmail.com>
 *
 *	$Id$
 */
#include "op_shutdown.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_shutdown
 */
op_shutdown::op_shutdown(shared_connection c, cluster* cl):
		op(c, "shutdown"),
		_cluster(cl),
		_server_name(""),
		_server_port(0) {
}

/**
 *	dtor for op_shutdown
 */
op_shutdown::~op_shutdown() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_shutdown::run_client(string node_server_name, int node_server_port) {
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
 *	SHUTDOWN [node_server_name] [node_server_port]
 */
int op_shutdown::_parse_text_server_parameters() {
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
		this->_server_name = q;
		log_debug("storing node server name [%s]", this->_server_name.c_str());

		// node server port
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no node server port found", 0);
			throw -1;
		}
		try {
			this->_server_port = boost::lexical_cast<int>(q);
			log_debug("storing node server port [%d]", this->_server_port);
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

int op_shutdown::_run_server() {
	if (this->_cluster->shutdown_node(this->_server_name, this->_server_port) < 0) {
		this->_send_result(result_server_error, "failed to shutdown");
		return -1;
	}

	return this->_send_result(result_ok);
}

int op_shutdown::_run_client(string node_server_name, int node_server_port) {
	char request[BUFSIZ];
	snprintf(request, sizeof(request), "shutdown %s %d", node_server_name.c_str(), node_server_port);

	return this->_send_request(request);
}

int op_shutdown::_parse_text_client_parameters() {
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
