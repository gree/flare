/**
 *	op_add.cc
 *
 *	implementation of gree::flare::op_add
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "op_add.h"
#include "queue_proxy_write.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_add
 */
op_add::op_add(shared_connection c, cluster* cl, storage* st):
		op_set(c, "add", cl, st) {
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
