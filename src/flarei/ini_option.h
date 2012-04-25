/**
 *	ini_option.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __INI_OPTION_H__
#define __INI_OPTION_H__

#include "ini.h"
#include "key_resolver.h"

namespace gree {
namespace flare {

#define	ini_option_object()			singleton<ini_option>::instance()

/**
 *	flarei global configuration class
 */
class ini_option : public ini {
private:
	int					_argc;
	char**			_argv;

	string			_config_path;
	string			_pid_path;
	bool				_daemonize;
	string			_data_dir;
	string			_log_facility;
	uint32_t		_max_connection;
	int					_monitor_threshold;
	int					_monitor_interval;
	int					_monitor_read_timeout;
	int					_net_read_timeout;
	int					_partition_modular_hint;
	int					_partition_modular_virtual;
	int					_partition_size;
	string			_partition_type;
	string			_key_hash_algorithm;
	string			_server_name;
	int					_server_port;
	string			_server_socket;
	int					_stack_size;
	int					_thread_pool_size;
	
public:
	static const uint32_t default_max_connection = 128;
	static const int default_monitor_threshold = 3;
	static const int default_monitor_interval = 5;
	static const int default_monitor_read_timeout = 1*1000;
	static const int default_net_read_timeout = 10*60*1000;
	static const int default_partition_modular_hint = 1;
	static const int default_partition_modular_virtual = 4096;
	static const int default_partition_size = 1024;
	static const int default_server_port = 12120;
	static const int default_stack_size = 128;
	static const int default_thread_pool_size = 5;

	ini_option();
	virtual ~ini_option();

	int load();
	int reload();

	int set_args(int argc, char** argv) { this->_argc = argc; this->_argv = argv; return 0; };

	string get_config_path() { return this->_config_path; };
	string get_pid_path() { return this->_pid_path; };
	bool is_daemonize() { return this->_daemonize; };
	string get_data_dir() { return this->_data_dir; };
	string get_log_facility() { return this->_log_facility; };
	uint32_t get_max_connection() { return this->_max_connection; };
	int get_monitor_threshold() { return this->_monitor_threshold; };
	int get_monitor_interval() { return this->_monitor_interval; };
	int get_monitor_read_timeout() { return this->_monitor_read_timeout; };
	int get_net_read_timeout() { return this->_net_read_timeout; };
	int get_partition_modular_hint() { return this->_partition_modular_hint; };
	int get_partition_modular_virtual() { return this->_partition_modular_virtual; };
	int get_partition_size() { return this->_partition_size; };
	string get_partition_type() { return this->_partition_type; };
	string get_key_hash_algorithm() { return this->_key_hash_algorithm; };
	string get_server_name() { return this->_server_name; };
	int get_server_port() { return this->_server_port; };
	string get_server_socket() { return this->_server_socket; };
	int get_stack_size() { return this->_stack_size; };
	int get_thread_pool_size() { return this->_thread_pool_size; };

private:
	int _setup_cli_option(program_options::options_description& option);
	int _setup_config_option(program_options:: options_description& option);
};

}	// namespace flare
}	// namespace gree

#endif // __INI_OPTION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
