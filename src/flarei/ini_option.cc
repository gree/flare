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
#include "storage.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for ini_option
 */
ini_option::ini_option():
		_argc(0),
		_argv(NULL),
		_config_path(""),
		_pid_path(""),
		_daemonize(false),
		_data_dir(""),
		_log_facility(""),
		_max_connection(default_max_connection),
		_monitor_threshold(default_monitor_threshold),
		_monitor_interval(default_monitor_interval),
		_monitor_read_timeout(default_monitor_read_timeout),
		_net_read_timeout(default_net_read_timeout),
		_partition_modular_hint(default_partition_modular_hint),
		_partition_modular_virtual(default_partition_modular_virtual),
		_partition_size(default_partition_size),
		_partition_type(""),
		_server_name(""),
		_server_port(default_server_port),
		_server_socket(""),
		_stack_size(default_stack_size),
		_thread_pool_size(default_thread_pool_size),
		_index_db(""),
		_log_stderr(false) {
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
	if (opt_var_map.count("pid")) {
		this->_pid_path = opt_var_map["pid"].as<string>();
	}
	if (opt_var_map.count("stderr")) {
		this->_log_stderr = true;
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
		if (opt_var_map.count("daemonize")) {
			this->_daemonize = true;
		}

		if (opt_var_map.count("data-dir")) {
			this->_data_dir = opt_var_map["data-dir"].as<string>();
		}
		if (this->_data_dir.empty()) {
			cout << "option [data-dir] is required" << endl;
			throw -1;
		}

		if (opt_var_map.count("log-facility")) {
			this->_log_facility = opt_var_map["log-facility"].as<string>();
		}

		if (opt_var_map.count("max-connection")) {
			this->_max_connection = opt_var_map["max-connection"].as<int>();
		}

		if (opt_var_map.count("monitor-threshold")) {
			this->_monitor_threshold = opt_var_map["monitor-threshold"].as<int>();
		}

		if (opt_var_map.count("monitor-interval")) {
			this->_monitor_interval = opt_var_map["monitor-interval"].as<int>();
		}

		if (opt_var_map.count("monitor-read-timeout")) {
			this->_monitor_read_timeout = opt_var_map["monitor-read-timeout"].as<int>();
		}

		if (opt_var_map.count("net-read-timeout")) {
			this->_net_read_timeout = opt_var_map["net-read-timeout"].as<int>();
		}

		if (opt_var_map.count("partition-modular-hint")) {
			this->_partition_modular_hint = opt_var_map["partition-modular-hint"].as<int>();
		}

		if (opt_var_map.count("partition-modular-virtual")) {
			this->_partition_modular_virtual = opt_var_map["partition-modular-virtual"].as<int>();
		}

		if (opt_var_map.count("partition-size")) {
			this->_partition_size = opt_var_map["partition-size"].as<int>();
		}

		if (opt_var_map.count("partition-type")) {
			key_resolver::type t;
			if (key_resolver::type_cast(opt_var_map["partition-type"].as<string>(), t) < 0) {
				cout << "unknown partition type [" << opt_var_map["partition-type"].as<string>() << "]" << endl;
				throw -1;
			}
			this->_partition_type = opt_var_map["partition-type"].as<string>();
		} else {
			this->_partition_type = key_resolver::type_cast(key_resolver::type_modular);
		}

		if (opt_var_map.count("key-hash-algorithm")) {
			const string& value = opt_var_map["key-hash-algorithm"].as<string>();
			storage::hash_algorithm ha;
			if (storage::hash_algorithm_cast(value, ha) < 0) {
				cout << "unknown hash algorithm [" << value << "]" << endl;
				throw -1;
			}
			this->_key_hash_algorithm = value;
		} else {
			this->_key_hash_algorithm = storage::hash_algorithm_cast(storage::hash_algorithm_simple);
		}

		if (opt_var_map.count("server-name")) {
			this->_server_name = opt_var_map["server-name"].as<string>();
		} else {
			util::get_fqdn(this->_server_name);
		}

		if (opt_var_map.count("server-port")) {
			this->_server_port = opt_var_map["server-port"].as<int>();
		}

		if (opt_var_map.count("server-socket")) {
			this->_server_socket = opt_var_map["server-socket"].as<string>();
		}

		if (opt_var_map.count("stack-size")) {
			this->_stack_size = opt_var_map["stack-size"].as<int>();
		}

		if (opt_var_map.count("thread-pool-size")) {
			this->_thread_pool_size = opt_var_map["thread-pool-size"].as<int>();
		}

		if (opt_var_map.count("index-db")) {
			this->_index_db = opt_var_map["index-db"].as<string>();
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
			log_notice("  log_facility:         %s -> %s", this->_log_facility.c_str(), opt_var_map["log-facility"].as<string>().c_str());
			this->_log_facility = opt_var_map["log-facility"].as<string>();
		}

		if (opt_var_map.count("max-connection")) {
			log_notice("  max_connection:       %d -> %d", this->_max_connection, opt_var_map["max-connection"].as<int>());
			this->_max_connection = opt_var_map["max-connection"].as<int>();
		}

		if (opt_var_map.count("monitor-threshold")) {
			log_notice("  monitor_threshold:    %d -> %d", this->_monitor_threshold, opt_var_map["monitor-threshold"].as<int>());
			this->_monitor_threshold = opt_var_map["monitor-threshold"].as<int>();
		}

		if (opt_var_map.count("monitor-interval")) {
			log_notice("  monitor_interval:     %d -> %d", this->_monitor_interval, opt_var_map["monitor-interval"].as<int>());
			this->_monitor_interval = opt_var_map["monitor-interval"].as<int>();
		}

		if (opt_var_map.count("monitor-read-timeout")) {
			log_notice("  monitor_read_timeout: %d -> %d", this->_monitor_read_timeout, opt_var_map["monitor-read-timeout"].as<int>());
			this->_monitor_read_timeout = opt_var_map["monitor-read-timeout"].as<int>();
		}

		if (opt_var_map.count("net-read-timeout")) {
			log_notice("  net_read_timeout:     %d -> %d", this->_net_read_timeout, opt_var_map["net-read-timeout"].as<int>());
			this->_net_read_timeout = opt_var_map["net-read-timeout"].as<int>();
		}

		if (opt_var_map.count("thread-pool-size")) {
			log_notice("  thread_pool_size:     %d -> %d", this->_thread_pool_size, opt_var_map["thread-pool-size"].as<int>());
			this->_thread_pool_size = opt_var_map["thread-pool-size"].as<int>();
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
		("pid,p",							program_options::value<string>(),	"path to pid file")
		("stderr,s",																						"output log to stderr")
		("version,v",																						"display version")
		("help,h",																							"display this help");

	return 0;
}

/**
 *	setup config option
 */
int ini_option::_setup_config_option(program_options::options_description& option) {
	option.add_options()
		("daemonize",																										"run as daemon")
		("data-dir",								program_options::value<string>(), 	"data directory")
		("log-facility",						program_options::value<string>(), 	"log facility (dynamic)")
		("max-connection",					program_options::value<int>(),			"max concurrent connections to accept (dynamic)")
		("monitor-threshold",				program_options::value<int>(),			"node server monitoring threshold (dynamic)")
		("monitor-interval",				program_options::value<int>(),			"node server monitoring interval (sec) (dynamic)")
		("monitor-read-timeout",		program_options::value<int>(),			"node server monitoring read timeout (millisec) (dynamic)")
		("partition-modular-hint",	program_options::value<int>(),			"partitioning hint (only for partition-type=modular)")
		("partition-modular-virtual",	program_options::value<int>(),		"partitioning virtual node size (only for partition-type=modular)")
		("key-hash-algorithm",			program_options::value<string>(),		"key hash algorithm")
		("partition-size",					program_options::value<int>(),			"max partition size")
		("partition-type",					program_options::value<string>(),		"partition type (modular: simple algorithm base)")
		("server-name",							program_options::value<string>(),		"my server name")
		("server-port",							program_options::value<int>(),			"my server port")
		("server-socket",						program_options::value<string>(),		"my server unix domain socket (optional)")
		("stack-size",							program_options::value<int>(),			"thread stack size (kb)")
		("thread-pool-size",				program_options::value<int>(),			"thread pool size (dynamic)")
		("index-db",								program_options::value<string>(),		"coordination database identifier");

	return 0;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
