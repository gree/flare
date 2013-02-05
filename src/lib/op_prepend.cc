/**
 *	op_prepend.cc
 *
 *	implementation of gree::flare::op_prepend
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_prepend.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_prepend
 */
op_prepend::op_prepend(shared_connection c, cluster* cl, storage* st):
		op_append(c, "prepend", binary_header::opcode_prepend, cl, st) {
	this->_behavior = storage::behavior_replace | storage::behavior_prepend;
}

/**
 *	ctor for op_prepend
 */
op_prepend::op_prepend(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_append(c, ident, opcode, cl, st) {
	this->_behavior = storage::behavior_replace | storage::behavior_prepend;
}

/**
 *	dtor for op_prepend
 */
op_prepend::~op_prepend() {
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
