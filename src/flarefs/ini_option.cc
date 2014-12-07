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
 *	ini_option.cc
 *	
 *	implementation of gree::flare::ini_option
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	@todo handling reload() SHOULD be more elegant:(
 *	
 *	$Id$
 */
#include "ini_option.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for ini_option
 */
ini_option::ini_option():
		_argc(0),
		_argv(NULL),
		_chunk_size(default_chunk_size),
		_config_path(""),
		_connection_pool_size(default_connection_pool_size),
		_data_dir(""),
		_fuse_allow_other(false),
		_fuse_allow_root(false),
		_mount_dir(""),
		_node_server_name(""),
		_node_server_port(default_node_server_port),
		_log_facility("") {
}

/**
 *	dtor for ini_option
 */
ini_option::~ini_option() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	load configuration from command line and/or config
 */
int ini_option::load() {
	if (this->_load) {
		log_warning("already loaded...", 0);
		return 0;
	}

	program_options::options_description cli_option("cli");
	program_options::options_description config_option("config");
	program_options::positional_options_description p;
	program_options::variables_map opt_var_map;

	this->_setup_cli_option(cli_option);
	this->_setup_config_option(config_option);

	program_options::options_description option;
	option.add(cli_option).add(config_option);

	// parse cli option
	try {
		program_options::store(program_options::command_line_parser(this->_argc, this->_argv).options(option).positional(p).run(), opt_var_map);
		program_options::notify(opt_var_map);
	} catch (program_options::error e) {
		cout << e.what() << endl;
		cout << option << endl;
		return -1;
	}

	// handle cli specific options
	if (opt_var_map.count("help")) {
		cout << option << endl;
		return -1;
	}
	if (opt_var_map.count("version")) {
		cout << PACKAGE_STRING << endl;
		return -1;
	}
	if (opt_var_map.count("config")) {
		this->_config_path = opt_var_map["config"].as<string>();
	}

	// parse config file
	if (this->_config_path.empty() == false) {
		try {
			ifstream ifs(this->_config_path.c_str());
			if (ifs.fail()) {
				cout << this->_config_path << " not found" << endl;
				throw -1;
			}
			program_options::store(program_options::parse_config_file(ifs, config_option), opt_var_map);
			program_options::notify(opt_var_map);
		} catch (int e) {
			cout << option << endl;
			return -1;
		} catch (program_options::error e) {
			cout << e.what() << endl;
			cout << option << endl;
			return -1;
		}
	}

	try {
		if (opt_var_map.count("chunk-size")) {
			this->_chunk_size = opt_var_map["chunk-size"].as<int>();
		}

		if (opt_var_map.count("connection-pool-size")) {
			this->_connection_pool_size = opt_var_map["connection-pool-size"].as<int>();
		}

		if (opt_var_map.count("data-dir")) {
			this->_data_dir = opt_var_map["data-dir"].as<string>();
		}
		if (this->_data_dir.empty()) {
			cout << "option [data-dir] is required" << endl;
			throw -1;
		}

		if (opt_var_map.count("fuse-allow-other")) {
			this->_fuse_allow_other = true;
		}
		if (opt_var_map.count("fuse-allow-root")) {
			this->_fuse_allow_root = true;
		}
		if (this->_fuse_allow_other && this->_fuse_allow_root) {
			cout << "options [fuse-allow-other] and [fuse-allow-root] are mutually exclusive" << endl;
			throw -1;
		}

		if (opt_var_map.count("mount-dir")) {
			this->_mount_dir = opt_var_map["mount-dir"].as<string>();
		}
		if (this->_mount_dir.empty()) {
			cout << "option [mount-dir] is required" << endl;
			throw -1;
		}

		if (opt_var_map.count("node-server-name")) {
			this->_node_server_name = opt_var_map["node-server-name"].as<string>();
		}
		if (this->_node_server_name.empty()) {
			cout << "option [node-server-name] is required" << endl;
			throw -1;
		}

		if (opt_var_map.count("node-server-port")) {
			this->_node_server_port = opt_var_map["node-server-port"].as<int>();
		}

		if (opt_var_map.count("log-facility")) {
			this->_log_facility = opt_var_map["log-facility"].as<string>();
		}
	} catch (int e) {
		cout << option << endl;
		return -1;
	}

	this->_load = true;

	return 0;
}

/**
 *	reload configuration from config
 */
int ini_option::reload() {
	if (this->_load == false) {
		log_warning("not yet loaded...", 0);
		return 0;
	}

	program_options::options_description config_option("config");
	program_options::variables_map opt_var_map;

	this->_setup_config_option(config_option);

	program_options::options_description option;
	option.add(config_option);

	// parse config file
	if (this->_config_path.empty() == false) {
		try {
			ifstream ifs(this->_config_path.c_str());
			if (ifs.fail()) {
				cout << this->_config_path << " not found" << endl;
				throw -1;
			}
			program_options::store(program_options::parse_config_file(ifs, config_option), opt_var_map);
			program_options::notify(opt_var_map);
		} catch (int e) {
			ostringstream ss;
			ss << option << endl;
			log_warning("%s", ss.str().c_str());
			return -1;
		} catch (program_options::error e) {
			ostringstream ss;
			ss << e.what() << endl;
			ss << option << endl;
			log_warning("%s", ss.str().c_str());
			return -1;
		}
	}

	try {
		if (opt_var_map.count("log-facility")) {
			log_info("  log_facility:      %s -> %s", this->_log_facility.c_str(), opt_var_map["log-facility"].as<string>().c_str());
			this->_log_facility = opt_var_map["log-facility"].as<string>();
		}
	} catch (int e) {
		ostringstream ss;
		ss << option << endl;
		log_warning("%s", ss.str().c_str());
		return -1;
	}

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
/**
 *	setup cli option
 */
int ini_option::_setup_cli_option(program_options::options_description& option) {
	option.add_options()
		("config,f",					program_options::value<string>(),	"path to config file")
		("version,v",																						"display version")
		("help,h",																							"display this help");

	return 0;
}

/**
 *	setup config option
 */
int ini_option::_setup_config_option(program_options::options_description& option) {
	option.add_options()
		("chunk-size",							program_options::value<int>(),			"file chunk size (kb)")
		("connection-pool-size",		program_options::value<int>(),			"connection pool size")
		("data-dir",								program_options::value<string>(),		"data directory")
		("fuse-allow-other",																						"[fuse option] allow other access")
		("fuse-allow-root",																							"[fuse option] allow root access")
		("mount-dir",								program_options::value<string>(),		"mount directory")
		("node-server-name",				program_options::value<string>(),		"node server name you connnect to")
		("node-server-port",				program_options::value<int>(),	 		"node server port you connnect to")
		("log-facility",						program_options::value<string>(),		"log facility (dynamic)");

	return 0;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
