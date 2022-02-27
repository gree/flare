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
		_back_log(default_back_log),
		_config_path(""),
		_pid_path(""),
		_daemonize(false),
		_data_dir(""),
		_log_facility(""),
		_max_connection(default_max_connection),
		_mutex_slot(default_mutex_slot),
#ifdef ENABLE_MYSQL_REPLICATION
		_mysql_replication(false),
		_mysql_replication_port(default_mysql_replication_port),
		_mysql_replication_id(default_mysql_replication_id),
		_mysql_replication_db(""),
		_mysql_replication_table(""),
#endif
		_noreply_window_limit(default_noreply_window_limit),
		_net_read_timeout(default_net_read_timeout),
		_proxy_concurrency(default_proxy_concurrency),
		_reconstruction_interval(default_reconstruction_interval),
		_reconstruction_bwlimit(default_reconstruction_bwlimit),
		_replication_type(""),
		_server_name(""),
		_server_port(default_server_port),
		_server_socket(""),
		_stack_size(default_stack_size),
		_storage_ap(default_storage_ap),
		_storage_fp(default_storage_fp),
		_storage_bucket_size(default_storage_bucket_size),
		_storage_cache_size(default_storage_cache_size),
		_storage_compress(""),
		_storage_large(false),
		_storage_lmemb(default_storage_lmemb),
		_storage_nmemb(default_storage_nmemb),
		_storage_dfunit(default_storage_dfunit),
		_storage_type(""),
		_thread_pool_size(default_thread_pool_size),
		_proxy_prior_netmask(default_proxy_prior_netmask),
		_max_total_thread_queue(default_max_total_thread_queue),
		_time_watcher_enabled(false),
		_time_watcher_polling_interval_msec(default_time_watcher_polling_interval_msec),
		_storage_access_watch_threshold_warn_msec(0),
		_storage_access_watch_threshold_ping_ng_msec(0),
		_cluster_replication(false),
		_cluster_replication_server_name(""),
		_cluster_replication_server_port(default_server_port),
		_cluster_replication_concurrency(default_proxy_concurrency),
		_cluster_replication_mode(""),
		_log_stderr(false) {
	pthread_mutex_init(&this->_mutex_index_servers, NULL);
}

/**
 *	dtor for ini_option
 */
ini_option::~ini_option() {
	if (pthread_mutex_destroy(&this->_mutex_index_servers) != 0) {
		log_err("failed to destroy the mutex for index_servers", 0);
	}
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
		if (opt_var_map.count("back-log")) {
			this->_back_log = opt_var_map["back-log"].as<int>();
		}

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

		if (this->_process_index_servers(opt_var_map) < 0) {
			cout << "invalid index servers are specified" << endl;
			throw -1;
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

#ifdef ENABLE_MYSQL_REPLICATION
		if (opt_var_map.count("mysql-replication")) {
			this->_mysql_replication = true;
		}

		if (opt_var_map.count("mysql-replication-port")) {
			this->_mysql_replication_port = opt_var_map["mysql-replication-port"].as<int>();
		}

		if (opt_var_map.count("mysql-replication-id")) {
			this->_mysql_replication_id = opt_var_map["mysql-replication-id"].as<uint32_t>();
		}

		if (opt_var_map.count("mysql-replication-db")) {
			this->_mysql_replication_db = opt_var_map["mysql-replication-db"].as<string>();
		} else {
			this->_mysql_replication_db = "flare";
		}

		if (opt_var_map.count("mysql-replication-table")) {
			this->_mysql_replication_table = opt_var_map["mysql-replication-table"].as<string>();
		} else {
			this->_mysql_replication_table = "flare";
		}
#endif

		if (opt_var_map.count("noreply-window-limit")) {
			this->_noreply_window_limit = opt_var_map["noreply-window-limit"].as<int>();
		}

		if (opt_var_map.count("net-read-timeout")) {
			this->_net_read_timeout = opt_var_map["net-read-timeout"].as<int>();
		}

		if (opt_var_map.count("proxy-concurrency")) {
			this->_proxy_concurrency = opt_var_map["proxy-concurrency"].as<int>();
		}

		if (opt_var_map.count("reconstruction-interval")) {
			this->_reconstruction_interval = opt_var_map["reconstruction-interval"].as<int>();
		}

		if (opt_var_map.count("reconstruction-bwlimit")) {
			this->_reconstruction_bwlimit = opt_var_map["reconstruction-bwlimit"].as<int>();
		}

		if (opt_var_map.count("replication-type")) {
			cluster::replication t;
			if (cluster::replication_cast(opt_var_map["replication-type"].as<string>(), t) < 0) {
				cout << "unknown replication type [" << opt_var_map["replication-type"].as<string>() << "]" << endl;
				throw -1;
			}
			this->_replication_type = opt_var_map["replication-type"].as<string>();
		} else {
			this->_replication_type = cluster::replication_cast(cluster::replication_async);
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

		if (opt_var_map.count("storage-ap")) {
			this->_storage_ap = opt_var_map["storage-ap"].as<uint32_t>();
		}

		if (opt_var_map.count("storage-fp")) {
			this->_storage_fp = opt_var_map["storage-fp"].as<uint32_t>();
		}

		if (opt_var_map.count("storage-bucket-size")) {
			this->_storage_bucket_size = opt_var_map["storage-bucket-size"].as<uint64_t>();
		}

		if (opt_var_map.count("storage-cache-size")) {
			this->_storage_cache_size = opt_var_map["storage-cache-size"].as<int>();
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

		if (opt_var_map.count("storage-lmemb")) {
			this->_storage_lmemb = opt_var_map["storage-lmemb"].as<int>();
		}

		if (opt_var_map.count("storage-nmemb")) {
			this->_storage_nmemb = opt_var_map["storage-nmemb"].as<int>();
		}

		if (opt_var_map.count("storage-dfunit")) {
			this->_storage_dfunit = opt_var_map["storage-dfunit"].as<int32_t>();
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

		if (opt_var_map.count("proxy-prior-netmask")) {
			this->_proxy_prior_netmask = opt_var_map["proxy-prior-netmask"].as<uint32_t>();
		}

		if (opt_var_map.count("max-total-thread-queue")) {
			this->_max_total_thread_queue = opt_var_map["max-total-thread-queue"].as<uint32_t>();
		}

		if (opt_var_map.count("time-watcher-enabled")) {
			this->_time_watcher_enabled = opt_var_map["time-watcher-enabled"].as<bool>();
		}

		if (opt_var_map.count("time-watcher-polling-interval-msec")) {
			this->_time_watcher_polling_interval_msec = opt_var_map["time-watcher-polling-interval-msec"].as<uint32_t>();
		}

		if (opt_var_map.count("storage-access-watch-threshold-warn-msec")) {
			this->_storage_access_watch_threshold_warn_msec = opt_var_map["storage-access-watch-threshold-warn-msec"].as<uint32_t>();
		}

		if (opt_var_map.count("storage-access-watch-threshold-ping-ng-msec")) {
			this->_storage_access_watch_threshold_ping_ng_msec = opt_var_map["storage-access-watch-threshold-ping-ng-msec"].as<uint32_t>();
		}

		if (opt_var_map.count("cluster-replication")) {
			this->_cluster_replication = opt_var_map["cluster-replication"].as<bool>();
		}

		if (opt_var_map.count("cluster-replication-server-name")) {
			this->_cluster_replication_server_name = opt_var_map["cluster-replication-server-name"].as<string>();
		}

		if (opt_var_map.count("cluster-replication-server-port")) {
			this->_cluster_replication_server_port = opt_var_map["cluster-replication-server-port"].as<int>();
		}

		if (opt_var_map.count("cluster-replication-concurrency")) {
			this->_cluster_replication_concurrency = opt_var_map["cluster-replication-concurrency"].as<int>();
		} else {
			this->_cluster_replication_concurrency = this->_proxy_concurrency;
		}

		if (opt_var_map.count("cluster-replication-mode")) {
			cluster_replication::mode m;
			if (cluster_replication::mode_cast(opt_var_map["cluster-replication-mode"].as<string>(), m) < 0) {
				log_warning("unknown cluster replication mode [%s]", opt_var_map["cluster-replication-mode"].as<string>().c_str());
				throw -1;
			}
			this->_cluster_replication_mode = opt_var_map["cluster-replication-mode"].as<string>();
		} else {
			this->_cluster_replication_mode = cluster_replication::mode_cast(cluster_replication::mode_duplicate);
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
			log_notice("  log_facility:           %s -> %s", this->_log_facility.c_str(), opt_var_map["log-facility"].as<string>().c_str());
			this->_log_facility = opt_var_map["log-facility"].as<string>();
		}

		if (opt_var_map.count("max-connection")) {
			log_notice("  max_connection:         %d -> %d", this->_max_connection, opt_var_map["max-connection"].as<int>());
			this->_max_connection = opt_var_map["max-connection"].as<int>();
		}

		if (opt_var_map.count("net-read-timeout")) {
			log_notice("  net_read_timeout:       %d -> %d", this->_net_read_timeout, opt_var_map["net-read-timeout"].as<int>());
			this->_net_read_timeout = opt_var_map["net-read-timeout"].as<int>();
		}

		if (opt_var_map.count("reconstruction-interval")) {
			log_notice("  reconstruction_interval: %d -> %d", this->_reconstruction_interval, opt_var_map["reconstruction-interval"].as<int>());
			this->_reconstruction_interval = opt_var_map["reconstruction-interval"].as<int>();
		}

		if (opt_var_map.count("reconstruction-bwlimit")) {
			log_notice("  reconstruction_bwlimit: %d -> %d", this->_reconstruction_bwlimit, opt_var_map["reconstruction-bwlimit"].as<int>());
			this->_reconstruction_bwlimit = opt_var_map["reconstruction-bwlimit"].as<int>();
		}

		if (opt_var_map.count("replication-type")) {
			log_notice("  replication_type:       %s -> %s", this->_replication_type.c_str(), opt_var_map["replication-type"].as<string>().c_str());

			cluster::replication t;
			if (cluster::replication_cast(opt_var_map["replication-type"].as<string>(), t) < 0) {
				log_warning("unknown replication type [%s]", opt_var_map["replication-type"].as<string>().c_str());
				throw -1;
			}
			this->_replication_type = opt_var_map["replication-type"].as<string>();
		}

		if (opt_var_map.count("thread-pool-size")) {
			log_notice("  thread_pool_size:       %d -> %d", this->_thread_pool_size, opt_var_map["thread-pool-size"].as<int>());
			this->_thread_pool_size = opt_var_map["thread-pool-size"].as<int>();
		}

		vector<cluster::index_server> index_servers = ini_option_object().get_index_servers();
		if (opt_var_map.count("index-servers")) {
			ostringstream ss;
			for (vector<cluster::index_server>::iterator it = index_servers.begin(); it != index_servers.end(); it++) {
				if (it != index_servers.begin()) {
					ss << ",";
				}
				ss << it->index_server_name.c_str() << ":" << it->index_server_port;
			}
			log_notice("  index_servers:          %s -> %s", ss.str().c_str(),  opt_var_map["index-servers"].as<string>().c_str());
		} else {
			if (index_servers.size() > 0) {
				cluster::index_server is = index_servers[0];
				if (opt_var_map.count("index-server-name")) {
					log_notice(" index_server_name: %s -> %s", is.index_server_name.c_str(), opt_var_map["index-server-name"].as<string>().c_str());
				}
				if (opt_var_map.count("index-server-port")) {
					log_notice(" index_server_port: %d -> %d", is.index_server_port, opt_var_map["index-server-port"].as<int>());
				}
			}
		}

		if (this->_process_index_servers(opt_var_map) < 0) {
			throw -1;
		}

		if (opt_var_map.count("max-total-thread-queue")) {
			log_notice("  max_total_thread_queue: %u -> %u", this->_max_total_thread_queue, opt_var_map["max-total-thread-queue"].as<uint32_t>());
			this->_max_total_thread_queue = opt_var_map["max-total-thread-queue"].as<uint32_t>();
		}

		if (opt_var_map.count("noreply-window-limit")) {
			log_notice("  noreply_window_limit: %d -> %d", this->_noreply_window_limit, opt_var_map["noreply-window-limit"].as<int>());
			this->_noreply_window_limit = opt_var_map["noreply-window-limit"].as<int>();
		}

		if (opt_var_map.count("time-watcher-enabled")) {
			log_notice("  time_watcher_enabled: %s -> %s",
					this->_time_watcher_enabled ? "true" : "false",
					opt_var_map["time-watcher-enabled"].as<bool>() ? "true" : "false");
			this->_time_watcher_enabled = opt_var_map["time-watcher-enabled"].as<bool>();
		}

		if (opt_var_map.count("time-watcher-polling-interval-msec")) {
			log_notice("  time_watcher_polling_interval_msec: %u -> %u", this->_time_watcher_polling_interval_msec, opt_var_map["time-watcher-polling-interval-msec"].as<uint32_t>());
			this->_time_watcher_polling_interval_msec = opt_var_map["time-watcher-polling-interval-msec"].as<uint32_t>();
		}

		if (opt_var_map.count("storage-access-watch-threshold-warn-msec")) {
			log_notice("  storage_access_watch_threshold_warn_msec: %u -> %u", this->_storage_access_watch_threshold_warn_msec, opt_var_map["storage-access-watch-threshold-warn-msec"].as<uint32_t>());
			this->_storage_access_watch_threshold_warn_msec = opt_var_map["storage-access-watch-threshold-warn-msec"].as<uint32_t>();
		}

		if (opt_var_map.count("storage-access-watch-threshold-ping-ng-msec")) {
			log_notice("  storage_access_watch_threshold_ping_ng_msec: %u -> %u", this->_storage_access_watch_threshold_ping_ng_msec, opt_var_map["storage-access-watch-threshold-ping-ng-msec"].as<uint32_t>());
			this->_storage_access_watch_threshold_ping_ng_msec = opt_var_map["storage-access-watch-threshold-ping-ng-msec"].as<uint32_t>();
		}

		if (opt_var_map.count("cluster-replication")) {
			log_notice("  cluster_replication: %s -> %s",
					this->_cluster_replication ? "true" : "false",
					opt_var_map["cluster-replication"].as<bool>() ? "true" : "false");
			this->_cluster_replication = opt_var_map["cluster-replication"].as<bool>();
		}

		if (opt_var_map.count("cluster-replication-server-name")) {
			log_notice("  cluster_replication_server_name: %s -> %s", this->_cluster_replication_server_name.c_str(), opt_var_map["cluster-replication-server-name"].as<string>().c_str());
			this->_cluster_replication_server_name = opt_var_map["cluster-replication-server-name"].as<string>();
		}

		if (opt_var_map.count("cluster-replication-server-port")) {
			log_notice("  cluster_replication_server_port: %d -> %d", this->_cluster_replication_server_port, opt_var_map["cluster-replication-server-port"].as<int>());
			this->_cluster_replication_server_port = opt_var_map["cluster-replication-server-port"].as<int>();
		}

		if (opt_var_map.count("cluster-replication-mode")) {
			log_notice("  cluster_replication_mode: %s -> %s",
					this->_cluster_replication_mode.c_str(),
					opt_var_map["cluster-replication-mode"].as<string>().c_str());
			cluster_replication::mode m;
			if (cluster_replication::mode_cast(opt_var_map["cluster-replication-mode"].as<string>(), m) < 0) {
				log_warning("unknown cluster replication mode [%s]", opt_var_map["cluster-replication-mode"].as<string>().c_str());
				throw -1;
			}
			this->_cluster_replication_mode = opt_var_map["cluster-replication-mode"].as<string>();
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
		("back-log",								program_options::value<int>(),			"back log")
		("daemonize",																										"run as daemon")
		("data-dir",								program_options::value<string>(),		"data directory")
		("index-servers",						program_options::value<string>(),		"index servers (name:port,...)")
		("index-server-name",				program_options::value<string>(),		"index server name")
		("index-server-port",				program_options::value<int>(),	 		"index server port")
		("log-facility",						program_options::value<string>(),		"log facility (dynamic)")
		("max-connection",					program_options::value<int>(),			"max concurrent connections to accept (dynamic)")
		("mutex-slot",							program_options::value<int>(),			"mutex slot size for storage I/O")
#ifdef ENABLE_MYSQL_REPLICATION
		("mysql-replication",																						"enable mysql replication")
		("mysql-replication-port",	program_options::value<int>(),			"mysql replication port")
		("mysql-replication-id",		program_options::value<uint32_t>(),	"mysql replication server id")
		("mysql-replication-db",		program_options::value<string>(),		"mysql replication database")
		("mysql-replication-table",	program_options::value<string>(),		"mysql replication table")
#endif
		("noreply-window-limit",		program_options::value<int>(),			"noreply window limit")
		("net-read-timeout",				program_options::value<int>(),			"network read timeout (sec) (dynamic)")
		("proxy-concurrency",				program_options::value<int>(),			"proxy request concurrency for each node")
		("reconstruction-interval",	program_options::value<int>(),			"master/slave dump interval in usec (dynamic)")
		("reconstruction-bwlimit",	program_options::value<int>(),			"master/slave dump limit I/O bandwidth; KBytes per second (dynamic)")
		("replication-type",				program_options::value<string>(),		"replication type (async, sync) (dynamic)")
		("server-name",							program_options::value<string>(),		"my server name")
		("server-port",							program_options::value<int>(),			"my server port")
		("server-socket",						program_options::value<string>(),		"my server unix domain socket (optional)")
		("stack-size",							program_options::value<int>(),			"thread stack size (kb)")
		("storage-ap",							program_options::value<uint32_t>(),	"storage size of record alignment by power of 2 (tch)")
		("storage-fp",							program_options::value<uint32_t>(),	"storage size of free block pool by power of 2 (tch)")
		("storage-bucket-size",			program_options::value<uint64_t>(),	"number of elements of the bucket array (tch)")
		("storage-cache-size",			program_options::value<int>(),			"storage header cache size")
		("storage-compress",				program_options::value<string>(),		"storage compress type (deflate, bz2, tcbs) (tch)")
		("storage-large",																								"use large storage (tch)")
		("storage-lmemb",						program_options::value<int>(),			"number of members in each leaf page (tcb)")
		("storage-nmemb",						program_options::value<int>(),			"number of members in each non-leaf page (tcb")
		("storage-dfunit",					program_options::value<int32_t>(),	"unit step number of auto defragmentation of a database object (tch/tcb)")
		("storage-type",						program_options::value<string>(),		"storage type (tch:tokyo cabinet hash database, tcb:tokyo cabinet b+tree database, kch:kyoto cabinet hash database)")
		("thread-pool-size",				program_options::value<int>(),			"thread pool size (dynamic)")
		("proxy-prior-netmask",			program_options::value<uint32_t>(),	"proxy prior netmask")
		("max-total-thread-queue",	program_options::value<uint32_t>(),	"max thread queue length (dynamic)")
		("time-watcher-enabled",												program_options::value<bool>(),			"time watcher enabled")
		("time-watcher-polling-interval-msec",					program_options::value<uint32_t>(),	"time watcher polling interval (msec)")
		("storage-access-watch-threshold-warn-msec",		program_options::value<uint32_t>(),	"threshold to log error when a thread accessing storage long time (msec)")
		("storage-access-watch-threshold-ping-ng-msec",	program_options::value<uint32_t>(),	"threshold to return ping ng when a thread accessing storage long time (msec)")
		("cluster-replication",							program_options::value<bool>(),		"enable cluster replication")
		("cluster-replication-server-name",	program_options::value<string>(),	"destination server name to replicate over cluster (dynamic)")
		("cluster-replication-server-port",	program_options::value<int>(),		"destination server port to replicate over cluster (dynamic)")
		("cluster-replication-concurrency",	program_options::value<int>(),		"concurrency to replicate over cluster")
		("cluster-replication-mode",				program_options::value<string>(),	"cluster replication mode (write, read, both) (write)");

	return 0;
}


int ini_option::_process_index_servers(program_options::variables_map& opt_var_map) {
	vector<cluster::index_server> v;
	if (opt_var_map.count("index-servers")) {
		static const char * pattern = ",?\\s*([^,:\\s]+):(\\d+)";
		string index_servers = opt_var_map["index-servers"].as<string>();
		static const boost::regex e(pattern);
		boost::smatch match;
		string::const_iterator start = index_servers.begin();
		string::const_iterator end = index_servers.end();

		while (boost::regex_search(start, end, match, e)) {
			string index_server_name = match.str(1);
			int index_server_port = default_index_server_port;
			try {
				index_server_port = boost::lexical_cast<int>(match.str(2));
			} catch (boost::bad_lexical_cast& e) {
				log_warning("invalid port number %s", match.str(2).c_str());
				return -1;
			}
			cluster::index_server is = { index_server_name, index_server_port };
			v.push_back(is);
			start = match[0].second;
		}

		if (v.size() == 0) {
			log_warning("option [index-servers] is invalid", 0);
			return -1;
		}
		if (opt_var_map.count("index-server-name") || opt_var_map.count("index-server-port")) {
			log_warning("option [index-server-port] is found although [index-servers] is specified", 0);
			return -1;
		}
	} else {
		string index_server_name("");
		int index_server_port(default_index_server_port);

		if (opt_var_map.count("index-server-name")) {
			index_server_name = opt_var_map["index-server-name"].as<string>();
		}
		if (opt_var_map.count("index-server-port")) {
			index_server_port = opt_var_map["index-server-port"].as<int>();
		}
		if (index_server_name.empty()) {
			log_warning("option [index-server-name] is required", 0);
			return -1;
		}
		cluster::index_server is = { index_server_name, index_server_port };
		v.push_back(is);
	}
	pthread_mutex_lock(&this->_mutex_index_servers);
	this->_index_servers = v;
	pthread_mutex_unlock(&this->_mutex_index_servers);
	return 0;
}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
