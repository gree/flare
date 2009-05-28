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

#endif // __INI_OPTION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
