/**
 *	op_stats_index.cc
 *	
 *	implementation of gree::flare::op_stats_index
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flarei.h"
#include "op_stats_index.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_stats_index
 */
op_stats_index::op_stats_index(shared_connection c):
		op_stats(c) {
}

/**
 *	dtor for op_stats_index
 */
op_stats_index::~op_stats_index() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_stats_index::_parse_text_server_parameters() {
	int r = op_stats::_parse_text_server_parameters();

	return r;
}

int op_stats_index::_run_server() {
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
		this->_send_stats_threads(singleton<flarei>::instance().get_thread_pool());
		break;
	case stats_type_threads_request:
		this->_send_stats_threads(singleton<flarei>::instance().get_thread_pool(), thread_pool::thread_type_request);
		break;
	case stats_type_threads_slave:
		break;
	case stats_type_nodes:
		this->_send_stats_nodes(singleton<flarei>::instance().get_cluster());
		break;
	case stats_type_threads_queue:
		this->_send_stats_threads_queue();
		break;
	default:
		this->_send_stats(singleton<flarei>::instance().get_thread_pool(), NULL);
		break;
	}
	this->_send_result(result_end);

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
