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
#include "cluster.h"
#include "cluster_replication.h"
#include "storage.h"

namespace gree {
namespace flare {

namespace program_options = boost::program_options;

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
	vector<cluster::index_server>	_index_servers;
	pthread_mutex_t								_mutex_index_servers;
	string			_log_facility;
	bool				_log_stderr;
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
	int32_t			_storage_dfunit;
	string			_storage_type;
	int					_thread_pool_size;
	uint32_t 		_proxy_prior_netmask;
	uint32_t 		_max_total_thread_queue;
	bool				_time_watcher_enabled;
	uint32_t 		_time_watcher_polling_interval_msec;
	uint32_t 		_storage_access_watch_threshold_warn_msec;
	uint32_t 		_storage_access_watch_threshold_ping_ng_msec;
	bool				_cluster_replication;
	string			_cluster_replication_server_name;
	int					_cluster_replication_server_port;
	int					_cluster_replication_concurrency;
	string			_cluster_replication_mode;

	// RocksDB backend tuning (ignored when storage-type != rocksdb).
	uint64_t		_rocksdb_block_cache_size_mb;
	uint64_t		_rocksdb_write_buffer_size_mb;
	int				_rocksdb_max_write_buffer_number;
	uint64_t		_rocksdb_wal_ttl_seconds;
	uint64_t		_rocksdb_wal_size_limit_mb;
	bool			_rocksdb_sync_writes;
	int				_rocksdb_resync_failure_threshold;
	// Hard cap on a single replicated WriteBatch in bytes. Batches
	// beyond this limit abort WAL sync with SERVER_ERROR batch_too_large
	// and the caller falls back to full-dump replication. 0 disables.
	uint64_t		_rocksdb_wal_max_batch_bytes;
	// Throttling for the WAL-sync path. 0 = inherit the global
	// reconstruction-bwlimit / reconstruction-interval so that
	// operators can leave them at zero and have WAL sync share the
	// existing tuning, while still letting them override with
	// WAL-specific values when the two phases have different
	// bandwidth budgets (e.g. daytime WAL vs. nightly full dump).
	int				_rocksdb_wal_sync_bwlimit;
	int				_rocksdb_wal_sync_interval;
	int				_rocksdb_backup_keep;
	int				_rocksdb_snapshot_bwlimit;
	// Administrative gate for the (unauthenticated) flush_all op.
	bool			_flush_all_enabled;
	// Background expire crawler (memcached lru_crawler equivalent): a
	// master-only sweep that physically deletes past-expire keys so they are
	// reclaimed and — being real deletes — replicate through the WAL to slaves.
	bool			_reap_expired;
	int				_reap_expired_interval;
	int				_reap_expired_chunk_size;
	int				_reap_expired_chunk_sleep_msec;
	// Native Prometheus /metrics endpoint (0 = disabled). Startup-only: the
	// listener binds once, a SIGHUP does not rebind it.
	int				_metrics_server_port;
	// Periodic full-checksum storage integrity check interval in seconds
	// (0 = disabled). Opt-in because VerifyChecksum reads every file.
	int				_storage_check_interval;
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
	// RocksDB defaults — chosen to match the historical constructor
	// defaults in storage_rocksdb.h so that existing deployments see
	// no behavior change if they don't set these in flared.conf.
	static const uint64_t default_rocksdb_block_cache_size_mb      = 512;
	static const uint64_t default_rocksdb_write_buffer_size_mb     = 64;
	static const int      default_rocksdb_max_write_buffer_number  = 3;
	static const uint64_t default_rocksdb_wal_ttl_seconds          = 86400;
	static const uint64_t default_rocksdb_wal_size_limit_mb        = 10240;
	static const int      default_rocksdb_resync_failure_threshold = 3;
	static const uint64_t default_rocksdb_wal_max_batch_bytes      = 16 * 1024 * 1024;  // 16 MB
	static const int      default_rocksdb_wal_sync_bwlimit         = 0;  // inherit
	static const int      default_rocksdb_wal_sync_interval        = 0;  // inherit
	static const int      default_rocksdb_backup_keep              = 7;
	static const int      default_rocksdb_snapshot_bwlimit         = 32768;  // KB/s ~= 1/4 of 1 Gbps
	static const bool     default_flush_all_enabled               = true;   // memcached compat; disable in exposed clusters
	static const bool     default_reap_expired                    = true;
	static const int      default_reap_expired_interval           = 300;    // sec between full sweeps
	static const int      default_reap_expired_chunk_size         = 10000;  // keys scanned per chunk
	static const int      default_reap_expired_chunk_sleep_msec   = 100;    // throttle sleep between chunks
	static const int      default_metrics_server_port             = 0;      // disabled
	static const int      default_storage_check_interval          = 0;      // disabled (opt-in; reads all files)
	static const int default_thread_pool_size = 5;
	static const uint32_t default_proxy_prior_netmask = 0x00;
	static const uint32_t default_max_total_thread_queue = 0;				// unlimited
	static const uint32_t default_time_watcher_polling_interval_msec = 0; // disabled
	static const uint32_t default_cluster_replication_concurrency = 1;

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
	vector<cluster::index_server> get_index_servers() {
		vector<cluster::index_server> v;
		pthread_mutex_lock(&this->_mutex_index_servers);
		v = this->_index_servers;
		pthread_mutex_unlock(&this->_mutex_index_servers);
		return v;
	};
	string get_log_facility() { return this->_log_facility; };
	bool get_log_stderr() { return this->_log_stderr; };
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
	bool get_time_watcher_enabled() { return this->_time_watcher_enabled; };
	uint32_t get_time_watcher_polling_interval_msec() { return this->_time_watcher_polling_interval_msec; };
	uint32_t get_storage_access_watch_threshold_warn_msec() { return this->_storage_access_watch_threshold_warn_msec; };
	uint32_t get_storage_access_watch_threshold_ping_ng_msec() { return this->_storage_access_watch_threshold_ping_ng_msec; };
	bool is_cluster_replication() { return this->_cluster_replication; }
	string get_cluster_replication_server_name() { return this->_cluster_replication_server_name; };
	int get_cluster_replication_server_port() { return this->_cluster_replication_server_port; }
	int get_cluster_replication_concurrency() { return this->_cluster_replication_concurrency; };
	string get_cluster_replication_mode() { return this->_cluster_replication_mode; }

	uint64_t get_rocksdb_block_cache_size_mb() { return this->_rocksdb_block_cache_size_mb; }
	uint64_t get_rocksdb_write_buffer_size_mb() { return this->_rocksdb_write_buffer_size_mb; }
	int get_rocksdb_max_write_buffer_number() { return this->_rocksdb_max_write_buffer_number; }
	uint64_t get_rocksdb_wal_ttl_seconds() { return this->_rocksdb_wal_ttl_seconds; }
	uint64_t get_rocksdb_wal_size_limit_mb() { return this->_rocksdb_wal_size_limit_mb; }
	bool is_rocksdb_sync_writes() { return this->_rocksdb_sync_writes; }
	int get_rocksdb_resync_failure_threshold() { return this->_rocksdb_resync_failure_threshold; }
	uint64_t get_rocksdb_wal_max_batch_bytes() { return this->_rocksdb_wal_max_batch_bytes; }
	int get_rocksdb_wal_sync_bwlimit() { return this->_rocksdb_wal_sync_bwlimit; }
	int get_rocksdb_wal_sync_interval() { return this->_rocksdb_wal_sync_interval; }
	int get_rocksdb_backup_keep() { return this->_rocksdb_backup_keep; }
	int get_rocksdb_snapshot_bwlimit() { return this->_rocksdb_snapshot_bwlimit; }
	bool is_flush_all_enabled() { return this->_flush_all_enabled; }
	bool is_reap_expired() { return this->_reap_expired; }
	int get_reap_expired_interval() { return this->_reap_expired_interval; }
	int get_reap_expired_chunk_size() { return this->_reap_expired_chunk_size; }
	int get_reap_expired_chunk_sleep_msec() { return this->_reap_expired_chunk_sleep_msec; }
	int get_metrics_server_port() { return this->_metrics_server_port; }
	int get_storage_check_interval() { return this->_storage_check_interval; }

private:
	int _setup_cli_option(program_options::options_description& option);
	int _setup_config_option(program_options:: options_description& option);
	int _process_index_servers(program_options::variables_map& opt_var_map);
};

}	// namespace flare
}	// namespace gree

#endif // INI_OPTION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
