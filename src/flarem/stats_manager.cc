/**
 *	stats_manager.cc
 *	
 *	implementation of gree::flare::stats_manager
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flarem.h"
#include "stats_manager.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for stats_manager
 */
stats_manager::stats_manager() {
}

/**
 *	dtor for stats_manager
 */
stats_manager::~stats_manager() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
uint32_t stats_manager::get_curr_connections(thread_pool* tp) {
	return tp->get_thread_size(flarem::thread_type_request);
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent

