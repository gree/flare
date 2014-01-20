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
#include "cluster.h"
#include "storage.h"

namespace gree {
namespace flare {

#define	ini_option_object()			singleton<ini_option>::instance()

/**
 *	flared global configuration class
 */
class ini_option : public ini {
private:
	int					_argc;
	char**			_argv;

	int					_back_log;
	string			_config_path;
	string			_pid_path;
	bool				_daemonize;
	string			_data_dir;
	string			_index_server_name;
	int					_index_server_port;
	string			_log_facility;
	uint32_t		_max_connection;
	int					_mutex_slot;
#ifdef ENABLE_MYSQL_REPLICATION
	bool				_mysql_replication;
	int					_mysql_replication_port;
	uint32_t		_mysql_replication_id;
	string			_mysql_replication_db;
	string			_mysql_replication_table;
#endif
	int					_noreply_window_limit;
	int					_net_read_timeout;
	int					_proxy_concurrency;
	int					_reconstruction_interval;
	int					_reconstruction_bwlimit;
	string			_replication_type;
	string			_server_name;
	int					_server_port;
	string			_server_socket;
	int					_stack_size;
	uint32_t		_storage_ap;
	uint32_t		_storage_fp;
	uint64_t		_storage_bucket_size;
	int					_storage_cache_size;
	string			_storage_compress;
	bool				_storage_large;
	int					_storage_lmemb;
	int					_storage_nmemb;
	int32_t				_storage_dfunit;
	string			_storage_type;
	int					_thread_pool_size;
	uint32_t 		_proxy_prior_netmask;
	uint32_t 		_max_total_thread_queue;
public:
	static const int default_back_log = 30;
	static const int default_index_server_port = 12120;
	static const uint32_t default_max_connection = 128;
	static const int default_mutex_slot = 64;
#ifdef ENABLE_MYSQL_REPLICATION
	static const int default_mysql_replication_port = 12122;
	static const int default_mysql_replication_id = 19790217;
#endif
	static const int default_noreply_window_limit = 0;						// disabled
	static const int default_net_read_timeout = 10*60;						// sec
	static const int default_proxy_concurrency = 2;
	static const int default_reconstruction_interval = 0;
	static const int default_reconstruction_bwlimit = 0;
	static const int default_server_port = 12121;
	static const int default_stack_size = 128;
	static const uint32_t default_storage_ap = 4;
	static const uint32_t default_storage_fp = 10;
	static const uint64_t default_storage_bucket_size = 131071;
	static const int default_storage_cache_size = 65536;
	static const int default_storage_lmemb = 128;
	static const int default_storage_nmemb = 256;
	static const int32_t default_storage_dfunit = 0;						// disable dynamic defragmentation
	static const int default_thread_pool_size = 5;
	static const uint32_t default_proxy_prior_netmask = 0x00;
	static const uint32_t default_max_total_thread_queue = 0;				// unlimited

	ini_option();
	virtual ~ini_option();

	int load();
	int reload();

	int set_args(int argc, char** argv) { this->_argc = argc; this->_argv = argv; return 0; };

	int get_back_log() { return this->_back_log; };
	string get_config_path() { return this->_config_path; };
	string get_pid_path() { return this->_pid_path; };
	bool is_daemonize() { return this->_daemonize; };
	string get_data_dir() { return this->_data_dir; };
	string get_index_server_name() { return this->_index_server_name; };
	int get_index_server_port() { return this->_index_server_port; };
	string get_log_facility() { return this->_log_facility; };
	uint32_t get_max_connection() { return this->_max_connection; };
	int get_mutex_slot() { return this->_mutex_slot; };
#ifdef ENABLE_MYSQL_REPLICATION
	bool is_mysql_replication() { return this->_mysql_replication; };
	int get_mysql_replication_port() { return this->_mysql_replication_port; };
	uint32_t get_mysql_replication_id() { return this->_mysql_replication_id; };
	string get_mysql_replication_db() { return this->_mysql_replication_db; };
	string get_mysql_replication_table() { return this->_mysql_replication_table; };
#endif
	int get_noreply_window_limit() { return this->_noreply_window_limit; };
	int get_net_read_timeout() { return this->_net_read_timeout; };
	int get_proxy_concurrency() { return this->_proxy_concurrency; };
	int get_reconstruction_interval() { return this->_reconstruction_interval; };
	int get_reconstruction_bwlimit() { return this->_reconstruction_bwlimit; };
	string get_replication_type() { return this->_replication_type; };
	string get_server_name() { return this->_server_name; };
	int get_server_port() { return this->_server_port; };
	string get_server_socket() { return this->_server_socket; };
	int get_stack_size() { return this->_stack_size; };
	uint32_t get_storage_ap() { return this->_storage_ap; };
	uint32_t get_storage_fp() { return this->_storage_fp; };
	uint64_t get_storage_bucket_size() { return this->_storage_bucket_size; };
	int get_storage_cache_size() { return this->_storage_cache_size; };
	string get_storage_compress() { return this->_storage_compress; };
	bool is_storage_large() { return this->_storage_large; };
	int get_storage_lmemb() { return this->_storage_lmemb; };
	int get_storage_nmemb() { return this->_storage_nmemb; };
	int32_t get_storage_dfunit() { return this->_storage_dfunit; };
	string get_storage_type() { return this->_storage_type; };
	int get_thread_pool_size() { return this->_thread_pool_size; };
	uint32_t get_proxy_prior_netmask() { return this->_proxy_prior_netmask; };
	uint32_t get_max_total_thread_queue() { return this->_max_total_thread_queue; };

private:
	int _setup_cli_option(program_options::options_description& option);
	int _setup_config_option(program_options:: options_description& option);
};

}	// namespace flare
}	// namespace gree

#endif // INI_OPTION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
