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
 *	show_node.cc
 *	
 *	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
 *	
 *	$Id$
 */
#include <sstream>
#include "show_node.h"
#include "ini_option.h"

#define PUSH_BACK_STRING_WITH_STREAM(stream_push_value) \
	push_back(static_cast<ostringstream&>(ostringstream().flush() << stream_push_value).str())

namespace gree {
namespace flare {

vector<string> show_node::lines() {
	vector<string> l;

  l.PUSH_BACK_STRING_WITH_STREAM("back_log:               " << ini_option_object().get_back_log());
	l.PUSH_BACK_STRING_WITH_STREAM("config_path:            " << ini_option_object().get_config_path());
	l.PUSH_BACK_STRING_WITH_STREAM("pid_path:               " << ini_option_object().get_pid_path());
	l.PUSH_BACK_STRING_WITH_STREAM("daemonize:              " << (ini_option_object().is_daemonize() ? "true" : "false"));
	l.PUSH_BACK_STRING_WITH_STREAM("data_dir:               " << ini_option_object().get_data_dir());
	l.push_back(show_node::index_servers_line());
	l.PUSH_BACK_STRING_WITH_STREAM("max_connection:         " << ini_option_object().get_max_connection());
	l.PUSH_BACK_STRING_WITH_STREAM("mutex_slot:             " << ini_option_object().get_mutex_slot());
#ifdef ENABLE_MYSQL_REPLICATION
	l.PUSH_BACK_STRING_WITH_STREAM("mysql_replication:      " << (ini_option_object().is_mysql_replication() ? "true" : "false"));
	l.PUSH_BACK_STRING_WITH_STREAM("mysql_replication_port: " << ini_option_object().get_mysql_replication_port());
	l.PUSH_BACK_STRING_WITH_STREAM("mysql_replication_id:   " << ini_option_object().get_mysql_replication_id());
	l.PUSH_BACK_STRING_WITH_STREAM("mysql_replication_db:   " << ini_option_object().get_mysql_replication_db());
	l.PUSH_BACK_STRING_WITH_STREAM("mysql_replication_table:" << ini_option_object().get_mysql_replication_table());
#endif
	l.PUSH_BACK_STRING_WITH_STREAM("noreply_window_limit:   " << ini_option_object().get_noreply_window_limit());
	l.PUSH_BACK_STRING_WITH_STREAM("net_read_timeout:       " << ini_option_object().get_net_read_timeout());
	l.PUSH_BACK_STRING_WITH_STREAM("proxy_concurrency:      " << ini_option_object().get_proxy_concurrency());
	l.PUSH_BACK_STRING_WITH_STREAM("reconstruction_interval:" << ini_option_object().get_reconstruction_interval());
	l.PUSH_BACK_STRING_WITH_STREAM("reconstruction_bwlimit: " << ini_option_object().get_reconstruction_bwlimit());
	l.PUSH_BACK_STRING_WITH_STREAM("replication_type:       " << ini_option_object().get_replication_type());
	l.PUSH_BACK_STRING_WITH_STREAM("server_name:            " << ini_option_object().get_server_name());
	l.PUSH_BACK_STRING_WITH_STREAM("server_port:            " << ini_option_object().get_server_port());
	l.PUSH_BACK_STRING_WITH_STREAM("server_socket:          " << ini_option_object().get_server_socket());
	l.PUSH_BACK_STRING_WITH_STREAM("stack_size:             " << ini_option_object().get_stack_size());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_ap:             " << ini_option_object().get_storage_ap());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_bucket_size:    " << ini_option_object().get_storage_bucket_size());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_cache_size:     " << ini_option_object().get_storage_cache_size());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_compress:       " << ini_option_object().get_storage_compress());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_large:          " << (ini_option_object().is_storage_large() ? "true" : "false"));
	l.PUSH_BACK_STRING_WITH_STREAM("storage_lmemb:          " << ini_option_object().get_storage_lmemb());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_nmemb:          " << ini_option_object().get_storage_nmemb());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_dfunit:         " << ini_option_object().get_storage_dfunit());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_type:           " << ini_option_object().get_storage_type());
	l.PUSH_BACK_STRING_WITH_STREAM("thread_pool_size:       " << ini_option_object().get_thread_pool_size());
	l.PUSH_BACK_STRING_WITH_STREAM("proxy_prior_netmask:    " << ini_option_object().get_proxy_prior_netmask());
	l.PUSH_BACK_STRING_WITH_STREAM("max_total_thread_queue: " << ini_option_object().get_max_total_thread_queue());
	l.PUSH_BACK_STRING_WITH_STREAM("time_watcher_enabled:   " << (ini_option_object().get_time_watcher_enabled() ? "true" : "false"));
	l.PUSH_BACK_STRING_WITH_STREAM("time_watcher_polling_interval_msec: " << ini_option_object().get_time_watcher_polling_interval_msec());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_access_watch_threshold_warn_msec: " << ini_option_object().get_storage_access_watch_threshold_warn_msec());
	l.PUSH_BACK_STRING_WITH_STREAM("storage_access_watch_threshold_ping_ng_msec: " << ini_option_object().get_storage_access_watch_threshold_ping_ng_msec());
	l.PUSH_BACK_STRING_WITH_STREAM("cluster_replication:    " << ini_option_object().is_cluster_replication());
	l.PUSH_BACK_STRING_WITH_STREAM("cluster_replication_server_name: " << ini_option_object().get_cluster_replication_server_name());
	l.PUSH_BACK_STRING_WITH_STREAM("cluster_replication_server_port: " << ini_option_object().get_cluster_replication_server_port());
	l.PUSH_BACK_STRING_WITH_STREAM("cluster_replication_concurrency: " << ini_option_object().get_cluster_replication_concurrency());
	l.PUSH_BACK_STRING_WITH_STREAM("cluster_replication_mode: " << ini_option_object().get_cluster_replication_mode());

	return l;
}

string show_node::index_servers_line() {
	vector<cluster::index_server> index_servers = ini_option_object().get_index_servers();
	ostringstream oss;
	oss << "index_server(s):        ";
	vector<cluster::index_server>::iterator it = index_servers.begin();
	if (index_servers.size() == 0) {
		return oss.str();
	}

	oss << it->index_server_name << ":" << it->index_server_port;
	it++;
	while (it != index_servers.end()) {
		oss << ", ";
		oss << it->index_server_name << ":" << it->index_server_port;
		it++;
	}

	return oss.str();
}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
