/**
 *	op_show_node.cc
 *	
 *	implementation of gree::flare::op_show_node
 *
 *	@author	Takanori Sejima <takanori.sejima@gmail.com>
 *	
 *	$Id$
 */
#include "flared.h"
#include "ini_option.h"
#include "op_show_node.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_show_node
 */
op_show_node::op_show_node(shared_connection c):
		op_show(c) {
}

/**
 *	dtor for op_show_node
 */
op_show_node::~op_show_node() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_show_node::_parse_server_parameter() {
	int r = op_show::_parse_server_parameter();

	return r;
}

int op_show_node::_run_server() {
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

int op_show_node::_send_show_variables() {
	ostringstream s;

	s << "back_log:               " << ini_option_object().get_back_log() << line_delimiter;
	s << "config_path:            " << ini_option_object().get_config_path().c_str() << line_delimiter;
	s << "pid_path:               " << ini_option_object().get_pid_path().c_str() << line_delimiter;
	s << "daemonize:              " << (ini_option_object().is_daemonize() ? "true" : "false") << line_delimiter;
	s << "data_dir:               " << ini_option_object().get_data_dir().c_str() << line_delimiter;
	s << "index_server_name:      " << ini_option_object().get_index_server_name().c_str() << line_delimiter;
	s << "index_server_port:      " << ini_option_object().get_index_server_port() << line_delimiter;
	s << "max_connection:         " << ini_option_object().get_max_connection() << line_delimiter;
	s << "mutex_slot:             " << ini_option_object().get_mutex_slot() << line_delimiter;
#ifdef ENABLE_MYSQL_REPLICATION
	s << "mysql_replication:      " << (ini_option_object().is_mysql_replication() ? "true" : "false") << line_delimiter;
	s << "mysql_replication_port: " << ini_option_object().get_mysql_replication_port() << line_delimiter;
	s << "mysql_replication_id:   " << ini_option_object().get_mysql_replication_id() << line_delimiter;
	s << "mysql_replication_db:   " << ini_option_object().get_mysql_replication_db().c_str() << line_delimiter;
	s << "mysql_replication_table:" << ini_option_object().get_mysql_replication_table().c_str() << line_delimiter;
#endif
	s << "net_read_timeout:       " << ini_option_object().get_net_read_timeout() << line_delimiter;
	s << "proxy_concurrency:      " << ini_option_object().get_proxy_concurrency() << line_delimiter;
	s << "reconstruction_interval:" << ini_option_object().get_reconstruction_interval() << line_delimiter;
	s << "reconstruction_bwlimit: " << ini_option_object().get_reconstruction_bwlimit() << line_delimiter;
	s << "replication_type:       " << ini_option_object().get_replication_type().c_str() << line_delimiter;
	s << "server_name:            " << ini_option_object().get_server_name().c_str() << line_delimiter;
	s << "server_port:            " << ini_option_object().get_server_port() << line_delimiter;
	s << "server_socket:          " << ini_option_object().get_server_socket().c_str() << line_delimiter;
	s << "stack_size:             " << ini_option_object().get_stack_size() << line_delimiter;
	s << "storage_ap:             " << ini_option_object().get_storage_ap() << line_delimiter;
	s << "storage_bucket_size:    " << ini_option_object().get_storage_bucket_size() << line_delimiter;
	s << "storage_cache_size:     " << ini_option_object().get_storage_cache_size() << line_delimiter;
	s << "storage_compress:       " << ini_option_object().get_storage_compress().c_str() << line_delimiter;
	s << "storage_large:          " << (ini_option_object().is_storage_large() ? "true": "false") << line_delimiter;
	s << "storage_lmemb:          " << ini_option_object().get_storage_lmemb() << line_delimiter;
	s << "storage_nmemb:          " << ini_option_object().get_storage_nmemb() << line_delimiter;
	s << "storage_dfunit:         " << ini_option_object().get_storage_dfunit() << line_delimiter;
	s << "storage_type:           " << ini_option_object().get_storage_type().c_str() << line_delimiter;
	s << "thread_pool_size:       " << ini_option_object().get_thread_pool_size() << line_delimiter;
	s << "proxy_prior_netmask:    " << ini_option_object().get_proxy_prior_netmask() << line_delimiter;
	s << "max_total_thread_queue: " << ini_option_object().get_max_total_thread_queue();

	this->_connection->writeline(s.str().c_str());

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
