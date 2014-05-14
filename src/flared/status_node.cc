/**
 *	status_node.cc
 *
 *	implementation of gree::flare::status_node
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#include "status_node.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for status_node
 */
status_node::status_node():
	status(),
	_node_status_code(node_status_ok) {
}

/**
 *	dtor for status_node
 */
status_node::~status_node() {
}
// }}}

// {{{ public methods
void status_node::set_node_status_code(node_status_code s) {
	this->_node_status_code = s;
	this->_status_code = this->_get_status_of(s);
}
// }}}

// {{{ protected methdos
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
