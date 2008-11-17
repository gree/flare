/**
 *	op_cas.cc
 *
 *	implementation of gree::flare::op_cas
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_cas.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_cas
 */
op_cas::op_cas(shared_connection c, cluster* cl, storage* st):
		op_set(c, "cas", cl, st) {
	this->_behavior = storage::behavior_cas;
}

/**
 *	dtor for op_cas
 */
op_cas::~op_cas() {
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
