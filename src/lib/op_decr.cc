/**
 *	op_decr.cc
 *
 *	implementation of gree::flare::op_decr
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_decr.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_decr
 */
op_decr::op_decr(shared_connection c, cluster* cl, storage* st):
		op_incr(c, "decr", cl, st) {
	this->_incr = false;
}

/**
 *	dtor for op_decr
 */
op_decr::~op_decr() {
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
