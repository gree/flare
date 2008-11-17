/**
 *	op_replace.cc
 *
 *	implementation of gree::flare::op_replace
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_replace.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_replace
 */
op_replace::op_replace(shared_connection c, cluster* cl, storage* st):
		op_set(c, "replace", cl, st) {
	this->_behavior = storage::behavior_replace;
}

/**
 *	dtor for op_replace
 */
op_replace::~op_replace() {
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
