/**
 *	op_gets.cc
 *
 *	implementation of gree::flare::op_gets
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_gets.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_gets
 */
op_gets::op_gets(shared_connection c, cluster* cl, storage* st):
		op_get(c, "gets", cl, st) {
	this->_append_version = true;
}

/**
 *	dtor for op_gets
 */
op_gets::~op_gets() {
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
