/**
 *	queue_node_sync.cc
 *
 *	implementation of gree::flare::queue_node_sync
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "queue_node_sync.h"
#include "op_node_sync.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_node_sync
 */
queue_node_sync::queue_node_sync(cluster* cl):
		thread_queue("node_sync"),
		_cluster(cl) {
	this->_node_vector = this->_cluster->get_node();
	this->_node_map_version = this->_cluster->get_node_map_version();
}

/**
 *	dtor for queue_node_sync
 */
queue_node_sync::~queue_node_sync() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int queue_node_sync::run(shared_connection c) {
	op_node_sync* p = new op_node_sync(c, this->_cluster);
	if (p->run_client(this->_node_vector, this->_node_map_version) < 0) {
		delete p;
		return -1;
	}
	delete p;

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
