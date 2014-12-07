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
 *	ini_option.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef INI_OPTION_H
#define INI_OPTION_H

#include "ini.h"

namespace gree {
namespace flare {

#define	ini_option_object()			singleton<ini_option>::instance()

/**
 *	flarefs global configuration class
 */
class ini_option : public ini {
private:
	int					_argc;
	char**			_argv;

	int					_chunk_size;
	string			_config_path;
	int					_connection_pool_size;
	string			_data_dir;
	bool				_fuse_allow_other;
	bool				_fuse_allow_root;
	string			_mount_dir;
	string			_node_server_name;
	int					_node_server_port;
	string			_log_facility;
	
public:
	static const int default_chunk_size = 8192;
	static const int default_connection_pool_size = 8;
	static const int default_node_server_port = 12121;

	ini_option();
	virtual ~ini_option();

	int load();
	int reload();

	int set_args(int argc, char** argv) { this->_argc = argc; this->_argv = argv; return 0; };

	int get_chunk_size() { return this->_chunk_size; };
	string get_config_path() { return this->_config_path; };
	int get_connection_pool_size() { return this->_connection_pool_size; };
	string get_data_dir() { return this->_data_dir; };
	bool is_fuse_allow_other() { return this->_fuse_allow_other; };
	bool is_fuse_allow_root() { return this->_fuse_allow_root; };
	string get_mount_dir() { return this->_mount_dir; };
	string get_node_server_name() { return this->_node_server_name; };
	int get_node_server_port() { return this->_node_server_port; };
	string get_log_facility() { return this->_log_facility; };

private:
	int _setup_cli_option(program_options::options_description& option);
	int _setup_config_option(program_options:: options_description& option);
};

}	// namespace flare
}	// namespace gree

#endif // INI_OPTION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
