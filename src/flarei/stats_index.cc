/**
 *	stats_index.cc
 *	
 *	implementation of gree::flare::stats_index
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flarei.h"
#include "stats_index.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for stats_index
 */
stats_index::stats_index() {
}

/**
 *	dtor for stats_index
 */
stats_index::~stats_index() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
uint32_t stats_index::get_curr_connections(thread_pool* tp) {
	return tp->get_thread_size(thread_pool::thread_type_request);
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
