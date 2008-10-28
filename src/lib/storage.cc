/**
 *	storage.cc
 *
 *	implementation of gree::flare::storage
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "storage.h"

namespace gree {
namespace flare {

// {{{
// }}}

// {{{ ctor/dtor
/**
 *	ctor for storage
 */
storage::storage(string data_dir):
		_open(false),
		_data_dir(data_dir) {
}

/**
 *	dtor for storage
 */
storage::~storage() {
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
