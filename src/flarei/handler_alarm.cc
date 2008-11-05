/**
 *	handler_alarm.cc
 *	
 *	implementation of gree::flare::handler_alarm
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "handler_alarm.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for handler_alarm
 */
handler_alarm::handler_alarm(shared_thread t):
		thread_handler(t) {
}

/**
 *	dtor for handler_alarm
 */
handler_alarm::~handler_alarm() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	run thread proc
 */
int handler_alarm::run() {
	for (;;) {
		this->_thread->set_state("wait");
		this->_thread->set_op("");

		stats_object->update_timestamp();

		sleep(1);
	}

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
