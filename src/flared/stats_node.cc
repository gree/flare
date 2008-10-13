/**
 *	stats_node.cc
 *	
 *	implementation of gree::flare::stats_node
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flared.h"
#include "stats_node.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for stats_node
 */
stats_node::stats_node() {
}

/**
 *	dtor for stats_node
 */
stats_node::~stats_node() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
uint32_t stats_node::get_curr_connections(thread_pool* tp) {
	return tp->get_thread_size(flared::thread_type_request);
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
