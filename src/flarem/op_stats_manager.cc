/**
 *	op_stats_manager.cc
 *	
 *	implementation of gree::flare::op_stats_manager
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flarem.h"
#include "op_stats_manager.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_stats_manager
 */
op_stats_manager::op_stats_manager(shared_connection c):
		op_stats(c) {
}

/**
 *	dtor for op_stats_manager
 */
op_stats_manager::~op_stats_manager() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_stats_manager::_parse_server_parameter() {
	int r = op_stats::_parse_server_parameter();

	return r;
}

int op_stats_manager::_run_server() {
	switch (this->_stats_type) {
	case stats_type_items:
		this->_send_stats_items();
		break;
	case stats_type_slabs:
		this->_send_stats_slabs();
		break;
	case stats_type_sizes:
		this->_send_stats_sizes();
		break;
	case stats_type_threads:
		this->_send_stats_threads(singleton<flarem>::instance().get_thread_pool());
		break;
	case stats_type_threads_request:
		this->_send_stats_threads(singleton<flarem>::instance().get_thread_pool(), flarem::thread_type_request);
		break;
	default:
		this->_send_stats(singleton<flarem>::instance().get_thread_pool());
		break;
	}
	this->_send_end();

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent

