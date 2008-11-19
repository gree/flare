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
		_config_path(""),
		_daemonize(false),
		_data_dir(""),
		_index_server_name(""),
		_index_server_port(default_index_server_port),
		_log_facility(""),
		_max_connection(default_max_connection),
		_mutex_slot(default_mutex_slot),
		_proxy_concurrency(default_proxy_concurrency),
		_server_name(""),
		_server_port(default_server_port),
		_storage_ap(default_storage_ap),
		_storage_bucket_size(default_storage_bucket_size),
		_storage_compress(""),
		_storage_large(false),
		_storage_type(""),
		_thread_pool_size(default_thread_pool_size) {
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

		if (opt_var_map.count("index-server-name")) {
			this->_index_server_name = opt_var_map["index-server-name"].as<string>();
		}
		if (this->_index_server_name.empty()) {
			cout << "option [index-server-name] is required" << endl;
			throw -1;
		}

		if (opt_var_map.count("index-server-port")) {
			this->_index_server_port = opt_var_map["index-server-port"].as<int>();
		}

		if (opt_var_map.count("log-facility")) {
			this->_log_facility = opt_var_map["log-facility"].as<string>();
		}

		if (opt_var_map.count("max-connection")) {
			this->_max_connection = opt_var_map["max-connection"].as<int>();
		}

		if (opt_var_map.count("mutex-slot")) {
			this->_mutex_slot = opt_var_map["mutex-slot"].as<int>();
		}

		if (opt_var_map.count("proxy-concurrency")) {
			this->_proxy_concurrency = opt_var_map["proxy-concurrency"].as<int>();
		}

		if (opt_var_map.count("server-name")) {
			this->_server_name = opt_var_map["server-name"].as<string>();
		} else {
			util::get_fqdn(this->_server_name);
		}

		if (opt_var_map.count("server-port")) {
			this->_server_port = opt_var_map["server-port"].as<int>();
		}

		if (opt_var_map.count("storage-ap")) {
			this->_storage_ap = opt_var_map["storage-ap"].as<uint32_t>();
		}

		if (opt_var_map.count("storage-bucket-size")) {
			this->_storage_bucket_size = opt_var_map["storage-bucket-size"].as<uint64_t>();
		}

		if (opt_var_map.count("storage-compress")) {
			storage::compress t;
			if (storage::compress_cast(opt_var_map["storage-compress"].as<string>(), t) < 0) {
				cout << "unknown storage compress [" << opt_var_map["storage-compress"].as<string>() << "]" << endl;
				throw -1;
			}
			this->_storage_compress = opt_var_map["storage-compress"].as<string>();
		} else {
			this->_storage_compress = storage::compress_cast(storage::compress_none);
		}

		if (opt_var_map.count("storage-large")) {
			this->_storage_large = true;
		}

		if (opt_var_map.count("storage-type")) {
			storage::type t;
			if (storage::type_cast(opt_var_map["storage-type"].as<string>(), t) < 0) {
				cout << "unknown storage type [" << opt_var_map["storage-type"].as<string>() << "]" << endl;
				throw -1;
			}
			this->_storage_type = opt_var_map["storage-type"].as<string>();
		} else {
			this->_storage_type = storage::type_cast(storage::type_tch);
		}

		if (opt_var_map.count("thread-pool-size")) {
			this->_thread_pool_size = opt_var_map["thread-pool-size"].as<int>();
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

		if (opt_var_map.count("max-connection")) {
			log_info("  max_connection:    %d -> %d", this->_max_connection, opt_var_map["max-connection"].as<int>());
			this->_max_connection = opt_var_map["max-connection"].as<int>();
		}

		if (opt_var_map.count("thread-pool-size")) {
			log_info("  thread_pool_size:  %d -> %d", this->_thread_pool_size, opt_var_map["thread-pool-size"].as<int>());
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
		("version,v",																						"display version")
		("help,h",																							"display this help");

	return 0;
}

/**
 *	setup config option
 */
int ini_option::_setup_config_option(program_options::options_description& option) {
	option.add_options()
		("daemonize",																							"run as daemon")
		("data-dir",					program_options::value<string>(), 	"data directory")
		("index-server-name",	program_options::value<string>(), 	"index server name")
		("index-server-port",	program_options::value<int>(),		 	"index server port")
		("log-facility",			program_options::value<string>(), 	"log facility (dynamic)")
		("max-connection",		program_options::value<int>(),			"max concurrent connections to accept (dynamic)")
		("mutex-slot",				program_options::value<int>(),			"mutex slot size for storage I/O")
		("proxy-concurrency",	program_options::value<int>(),			"proxy request concurrency for each node")
		("server-name",				program_options::value<string>(),		"my server name")
		("server-port",				program_options::value<int>(),			"my server port")
		("storage-ap",				program_options::value<uint32_t>(),	"storage size of record alignment by power of 2 (tch)")
		("storage-bucket-size",	program_options::value<uint64_t>(),	"number of elements of the bucket array (tch)")
		("storage-compress",	program_options::value<string>(),		"storage compress type (deflate, bz2, tcbs) (tch)")
		("storage-large",																					"use large storage (tch)")
		("storage-type",			program_options::value<string>(),		"storage type (tch:tokyo cabinet hash database)")
		("thread-pool-size",	program_options::value<int>(),			"thread pool size (dynamic)");

	return 0;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
