/**
 *	op_add.cc
 *
 *	implementation of gree::flare::op_add
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_add.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_add
 */
op_add::op_add(shared_connection c, cluster* cl, storage* st):
		op_set(c, "add", binary_header::opcode_add, cl, st) {
	this->_behavior = storage::behavior_add;
}

/**
 *	ctor for op_add
 */
op_add::op_add(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_set(c, ident, opcode, cl, st) {
	this->_behavior = storage::behavior_add;
}

/**
 *	dtor for op_add
 */
op_add::~op_add() {
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
