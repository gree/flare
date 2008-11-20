/**
 *	op_append.cc
 *
 *	implementation of gree::flare::op_append
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_append.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_append
 */
op_append::op_append(shared_connection c, cluster* cl, storage* st):
		op_set(c, "append", cl, st) {
	this->_behavior = storage::behavior_replace | storage::behavior_append;
}

/**
 *	dtor for op_append
 */
op_append::~op_append() {
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
