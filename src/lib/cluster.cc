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
#include "op_node_add.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for cluster
 */
cluster::cluster(thread_pool* tp):
		_thread_pool(tp),
		_index_server_name(""),
		_index_server_port(0) {
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
 *	startup proc for index process
 */
int cluster::startup_index() {
	this->_type = type_index;

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

	shared_connection c(_new_ connection());
	if (c->open(this->_index_server_name, this->_index_server_port) < 0) {
		log_err("failed to connect to index server", 0);
		return -1;
	}

	op_node_add* p = _new_ op_node_add(c, this);
	if (p->run_client() < 0) {
		log_err("failed to add node to index server", 0);
		return -1;
	}
	
	// set state and other nodes

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
