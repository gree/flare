/**
 *	op_getk.cc
 *
 *	implementation of gree::flare::op_getk
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 *	$Id$
 */
#include "op_getk.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_getk
 */
op_getk::op_getk(shared_connection c, cluster* cl, storage* st):
		op_get(c, "get", binary_header::opcode_getk, cl, st) {
}

/**
 *	ctor for op_getk
 */
op_getk::op_getk(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_get(c, ident, opcode, cl, st) {
}

/**
 *	dtor for op_getk
 */
op_getk::~op_getk() {
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
