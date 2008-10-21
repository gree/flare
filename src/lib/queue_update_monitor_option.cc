/**
 *	queue_update_monitor_option.cc
 *
 *	implementation of gree::flare::queue_update_monitor_option
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "queue_update_monitor_option.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_update_monitor_option
 */
queue_update_monitor_option::queue_update_monitor_option(int monitor_threshold, int monitor_interval):
		thread_queue("update_monitor_option"),
		_monitor_threshold(monitor_threshold),
		_monitor_interval(monitor_interval) {
}

/**
 *	dtor for queue_update_monitor_option
 */
queue_update_monitor_option::~queue_update_monitor_option() {
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
