/**
 *	queue_update_monitor_interval.cc
 *
 *	implementation of gree::flare::queue_update_monitor_interval
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "queue_update_monitor_interval.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_update_monitor_interval
 */
queue_update_monitor_interval::queue_update_monitor_interval(int monitor_inteval):
		thread_queue("update_monitor_interval"),
		_monitor_interval(monitor_inteval) {
}

/**
 *	dtor for queue_update_monitor_interval
 */
queue_update_monitor_interval::~queue_update_monitor_interval() {
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
