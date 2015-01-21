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
 *	op_show_index.cc
 *	
 *	implementation of gree::flare::op_show_index
 *
 *	@author	Takanori Sejima <takanori.sejima@gmail.com>
 *	
 *	$Id$
 */
#include "flarei.h"
#include "ini_option.h"
#include "op_show_index.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_show_index
 */
op_show_index::op_show_index(shared_connection c):
		op_show(c) {
}

/**
 *	dtor for op_show_index
 */
op_show_index::~op_show_index() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_show_index::_parse_text_server_parameters() {
	int r = op_show::_parse_text_server_parameters();

	return r;
}

int op_show_index::_run_server() {
	switch (this->_show_type) {
	case show_type_variables:
		this->_send_show_variables();
		break;
	default:
		break;
	}
	this->_send_result(result_end);

	return 0;
}

int op_show_index::_send_show_variables() {
	ostringstream s;

	s << "config_path:              " << ini_option_object().get_config_path().c_str() << line_delimiter;
	s << "pid_path:                 " << ini_option_object().get_pid_path().c_str() << line_delimiter;
	s << "daemonize:                " << (ini_option_object().is_daemonize() ? "true" : "false") << line_delimiter;
	s << "data_dir:                 " << ini_option_object().get_data_dir().c_str() << line_delimiter;
	s << "max_connection:           " << ini_option_object().get_max_connection() << line_delimiter;
	s << "monitor_threshold:        " << ini_option_object().get_monitor_threshold() << line_delimiter;
	s << "monitor_interval:         " << ini_option_object().get_monitor_interval() << line_delimiter;
	s << "monitor_read_timeout:     " << ini_option_object().get_monitor_read_timeout() << line_delimiter;
	s << "net_read_timeout:         " << ini_option_object().get_net_read_timeout() << line_delimiter;
	s << "partition_modular_hint:   " << ini_option_object().get_partition_modular_hint() << line_delimiter;
	s << "partition_modular_virtual:" << ini_option_object().get_partition_modular_virtual() << line_delimiter;
	s << "partition_size:           " << ini_option_object().get_partition_size() << line_delimiter;
	s << "partition_type:           " << ini_option_object().get_partition_type().c_str() << line_delimiter;
	s << "key_hash_algorithm:       " << ini_option_object().get_key_hash_algorithm().c_str() << line_delimiter;
	s << "server_name:              " << ini_option_object().get_server_name().c_str() << line_delimiter;
	s << "server_port:              " << ini_option_object().get_server_port() << line_delimiter;
	s << "server_socket:            " << ini_option_object().get_server_socket().c_str() << line_delimiter;
	s << "stack_size:               " << ini_option_object().get_stack_size() << line_delimiter;
	s << "thread_pool_size:         " << ini_option_object().get_thread_pool_size();

	this->_connection->writeline(s.str().c_str());

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
