/**
 *	handler_reconstruction.cc
 *
 *	implementation of gree::flare::handler_reconstruction
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "handler_reconstruction.h"
#include "op_dump.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_reconstruction
 */
handler_reconstruction::handler_reconstruction(shared_thread t, cluster* cl, storage* st, string node_server_name, int node_server_port, int partition, int partition_size, cluster::role r):
		thread_handler(t),
		_cluster(cl),
		_storage(st),
		_node_server_name(node_server_name),
		_node_server_port(node_server_port),
		_partition(partition),
		_partition_size(partition_size),
		_role(r) {
}

/**
 *	dtor for handler_reconstruction
 */
handler_reconstruction::~handler_reconstruction() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_reconstruction::run() {
	this->_thread->set_peer(this->_node_server_name, this->_node_server_port);
	this->_thread->set_state("connect");

	shared_connection c(new connection());
	this->_connection = c;
	if (c->open(this->_node_server_name, this->_node_server_port) < 0) {
		log_err("failed to connect to node server (name=%s, port=%d) -> deactivating node", this->_node_server_name.c_str(), this->_node_server_port);
		this->_cluster->deactivate_node();
		return -1;
	}

	op_dump* p = _new_ op_dump(c, this->_cluster, this->_storage);

	p->set_thread(this->_thread);
	this->_thread->set_state("execute");
	this->_thread->set_op(p->get_ident());

	if (p->run_client(this->_cluster->get_reconstruction_interval(), this->_partition, this->_partition_size) < 0) {
		_delete_(p);
		this->_cluster->deactivate_node();
		return -1;
	}

	_delete_(p);

	// node activation (slave only)
	if (this->_role == cluster::role_slave) {
		this->_cluster->activate_node();
	}

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
