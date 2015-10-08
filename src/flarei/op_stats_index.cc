/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
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
		this->_send_stats(singleton<flarei>::instance().get_thread_pool(),
				NULL,
				singleton<flarei>::instance().get_cluster());
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
