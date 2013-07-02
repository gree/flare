/**
 *	queue_node_state.cc
 *
 *	implementation of gree::flare::queue_node_state
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#include "queue_node_state.h"
#include "op_node_sync.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_node_state
 */
queue_node_state::queue_node_state(string node_server_name, int node_server_port, state_operation operation):
		thread_queue("node_state"),
		_node_server_name(node_server_name),
		_node_server_port(node_server_port),
		_operation(operation) {
}

/**
 *	dtor for queue_node_state
 */
queue_node_state::~queue_node_state() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
