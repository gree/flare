/**
 *	status_index.cc
 *
 *	implementation of gree:flare::status_index
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#include "status_index.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for status_index
 */
status_index::status_index():
	status(),
	_index_status_code(index_status_ok) {
}

/**
 *	dtor for status_index
 */
status_index::~status_index() {
}
// }}}

// {{{ public methods
void status_index::set_index_status_code(index_status_code s) {
	this->_index_status_code = s;
	this->_status_code = this->_get_status_of(s);
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
} // namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
