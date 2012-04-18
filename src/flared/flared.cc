/**
 *	flared.cc
 *
 *	implementation of gree::flare::flared (and some other global stuffs)
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "flared.h"
#include "handler_alarm.h"
#include "handler_request.h"
#ifdef ENABLE_MYSQL_REPLICATION
# include "handler_mysql_replication.h"
#endif

namespace gree {
namespace flare {

// This variable is set by main thread.
static volatile sig_atomic_t reload_request = 0;

// {{{ global functions
/**
 *	signal handler (SIGTERM/SIGINT)
 */
void sa_term_handler(int sig) {
	if (sig != SIGTERM && sig != SIGINT) {
		return;
	}
	log_notice("received signal [%s] -> requesting shutdown", sig == SIGTERM ? "SIGTERM" : "SIGINT");

	singleton<flared>::instance().request_shutdown();

	return;
}

/**
 *	signal handler (SIGHUP)
 */
void sa_hup_handler(int sig) {
	//
	// Set signal flag. 
	// Reload action is executed in the main loop.
	//
	reload_request = 1;
}

/**
 *	signal handler (SIGUSR1)
 */
void sa_usr1_handler(int sig) {
	log_notice("received signal [SIGUSR1]", 0);

	// just interrupting -> nothing to do
}
// }}}

// {{{ ctor/dtor
/**
 *	ctor for flared
 */
flared::flared():
		_server(NULL),
		_thread_pool(NULL),
		_cluster(NULL),
		_storage(NULL) {
}

/**
 *	dtor for flared
 */
flared::~flared() {
	if (this->_storage != NULL) {
		_delete_(this->_storage);
	}
	if (this->_server != NULL) {
		_delete_(this->_server);
	}
	if (this->_thread_pool != NULL) {
		_delete_(this->_thread_pool);
	}
	if (this->_cluster != NULL) {
		_delete_(this->_cluster);
	}
	if (stats_object != NULL) {
		_delete_(stats_object);
		stats_object = NULL;
	}

#ifdef MM_ALLOCATION_CHECK
	mm::dump_alloc_list();
#endif
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	flared application startup procs
 */
int flared::startup(int argc, char **argv) {
	ini_option_object().set_args(argc, argv);
	if (ini_option_object().load() < 0) {
		return -1;
	}

	singleton<logger>::instance().open(this->_ident, ini_option_object().get_log_facility());
	stats_object = _new_ stats_node();
	stats_object->startup();

	log_notice("%s version %s - system logger started", this->_ident.c_str(), PACKAGE_VERSION);

	log_notice("application startup in progress...", 0);
	log_notice("  back_log:               %d", ini_option_object().get_back_log());
	log_notice("  config_path:            %s", ini_option_object().get_config_path().c_str());
	log_notice("  pid_path:               %s", ini_option_object().get_pid_path().c_str());
	log_notice("  daemonize:              %s", ini_option_object().is_daemonize() ? "true" : "false");
	log_notice("  data_dir:               %s", ini_option_object().get_data_dir().c_str());
	log_notice("  index_server_name:      %s", ini_option_object().get_index_server_name().c_str());
	log_notice("  index_server_port:      %d", ini_option_object().get_index_server_port());
	log_notice("  max_connection:         %d", ini_option_object().get_max_connection());
	log_notice("  mutex_slot:             %d", ini_option_object().get_mutex_slot());
#ifdef ENABLE_MYSQL_REPLICATION
	log_notice("  mysql_replication:      %s", ini_option_object().is_mysql_replication() ? "true" : "false");
	log_notice("  mysql_replication_port: %d", ini_option_object().get_mysql_replication_port());
	log_notice("  mysql_replication_id:   %u", ini_option_object().get_mysql_replication_id());
	log_notice("  mysql_replication_db:   %s", ini_option_object().get_mysql_replication_db().c_str());
	log_notice("  mysql_replication_table:%s", ini_option_object().get_mysql_replication_table().c_str());
#endif
	log_notice("  noreply_window_limit:   %d", ini_option_object().get_noreply_window_limit());
	log_notice("  net_read_timeout:       %d", ini_option_object().get_net_read_timeout());
	log_notice("  proxy_concurrency:      %d", ini_option_object().get_proxy_concurrency());
	log_notice("  reconstruction_interval:%d", ini_option_object().get_reconstruction_interval());
	log_notice("  reconstruction_bwlimit: %d", ini_option_object().get_reconstruction_bwlimit());
	log_notice("  replication_type:       %s", ini_option_object().get_replication_type().c_str());
	log_notice("  server_name:            %s", ini_option_object().get_server_name().c_str());
	log_notice("  server_port:            %d", ini_option_object().get_server_port());
	log_notice("  server_socket:          %s", ini_option_object().get_server_socket().c_str());
	log_notice("  stack_size:             %d", ini_option_object().get_stack_size());
	log_notice("  storage_ap:             %u", ini_option_object().get_storage_ap());
	log_notice("  storage_bucket_size:    %llu", ini_option_object().get_storage_bucket_size());
	log_notice("  storage_cache_size:     %d", ini_option_object().get_storage_cache_size());
	log_notice("  storage_compress:       %s", ini_option_object().get_storage_compress().c_str());
	log_notice("  storage_large:          %s", ini_option_object().is_storage_large() ? "true" : "false");
	log_notice("  storage_lmemb:          %d", ini_option_object().get_storage_lmemb());
	log_notice("  storage_nmemb:          %d", ini_option_object().get_storage_nmemb());
	log_notice("  storage_dfunit:         %d", ini_option_object().get_storage_dfunit());
	log_notice("  storage_type:           %s", ini_option_object().get_storage_type().c_str());
	log_notice("  thread_pool_size:       %d", ini_option_object().get_thread_pool_size());
	log_notice("  proxy-prior-netmask:    %u", ini_option_object().get_proxy_prior_netmask());
	log_notice("  max-total-thread-queue: %u", ini_option_object().get_max_total_thread_queue());

	// startup procs
	if (this->_set_resource_limit() < 0) {
		return -1;
	}

	if (ini_option_object().is_daemonize()) {
		if (this->_daemonize() < 0) {
			return -1;
		}
	}

	if (this->_set_signal_handler() < 0) {
		return -1;
	}

	// application objects
	connection::read_timeout = ini_option_object().get_net_read_timeout() * 1000;		// -> msec
	this->_server = _new_ server();
	this->_server->set_back_log(ini_option_object().get_back_log());
	if (this->_server->listen(ini_option_object().get_server_port()) < 0) {
		return -1;
	}
	if (ini_option_object().get_server_socket().empty() == false) {
		if (this->_server->listen(ini_option_object().get_server_socket()) < 0) {
			return -1;
		}
	}

	this->_thread_pool = _new_ thread_pool(ini_option_object().get_thread_pool_size(), ini_option_object().get_stack_size());

	this->_cluster = _new_ cluster(this->_thread_pool, ini_option_object().get_data_dir(), ini_option_object().get_server_name(), ini_option_object().get_server_port());
	this->_cluster->set_proxy_concurrency(ini_option_object().get_proxy_concurrency());
	this->_cluster->set_reconstruction_interval(ini_option_object().get_reconstruction_interval());
	this->_cluster->set_reconstruction_bwlimit(ini_option_object().get_reconstruction_bwlimit());
	this->_cluster->set_replication_type(ini_option_object().get_replication_type());
	this->_cluster->set_max_total_thread_queue(ini_option_object().get_max_total_thread_queue());
	this->_cluster->set_noreply_window_limit(ini_option_object().get_noreply_window_limit());
	if (this->_cluster->startup_node(ini_option_object().get_index_server_name(),
									 ini_option_object().get_index_server_port(),
									 ini_option_object().get_proxy_prior_netmask()) < 0) {
		return -1;
	}

	storage::type t = storage::type_tch;
	storage::type_cast(ini_option_object().get_storage_type(), t);
	switch (t) {
	case storage::type_tch:
		this->_storage = _new_ storage_tch(ini_option_object().get_data_dir(),
				ini_option_object().get_mutex_slot(),
				ini_option_object().get_storage_ap(),
				ini_option_object().get_storage_bucket_size(),
				ini_option_object().get_storage_cache_size(),
				ini_option_object().get_storage_compress(),
				ini_option_object().is_storage_large(),
				ini_option_object().get_storage_dfunit());

		break;
	case storage::type_tcb:
		this->_storage = _new_ storage_tcb(ini_option_object().get_data_dir(),
				ini_option_object().get_mutex_slot(),
				ini_option_object().get_storage_ap(),
				ini_option_object().get_storage_bucket_size(),
				ini_option_object().get_storage_cache_size(),
				ini_option_object().get_storage_compress(),
				ini_option_object().is_storage_large(),
				ini_option_object().get_storage_lmemb(),
				ini_option_object().get_storage_nmemb(),
				ini_option_object().get_storage_dfunit());
		break;
	default:
		log_err("unknown storage type [%s]", ini_option_object().get_storage_type().c_str());
		return -1;
	}
	if (this->_storage->open() < 0) {
		return -1;
	}
	this->_cluster->set_storage(this->_storage);

	// creating alarm thread in advance
	shared_thread th_alarm = this->_thread_pool->get(thread_pool::thread_type_alarm);
	handler_alarm* h_alarm = _new_ handler_alarm(th_alarm);
	th_alarm->trigger(h_alarm);

#ifdef ENABLE_MYSQL_REPLICATION
	if (ini_option_object().is_mysql_replication()) {
		shared_thread th_mysql_replication = this->_thread_pool->get(thread_pool::thread_type_mysql_replication);
		handler_mysql_replication* h_mysql_replication = _new_ handler_mysql_replication(th_mysql_replication, this->_cluster);
		th_mysql_replication->trigger(h_mysql_replication);
	}
#endif

	if (this->_set_pid() < 0) {
		return -1;
	}

	return 0;
}

/**
 *	flared application running loop
 */
int flared::run() {
	log_notice("entering running loop", 0);

	for (;;) {
		if (this->_shutdown_request) {
			log_notice("shutdown request accepted -> breaking running loop", 0);
			log_notice("send shutdown message to index server", 0);
			if (this->_cluster->shutdown_node()) {
				log_warning("failed to send shutdown message", 0);
			}
			break;
		}

		if (reload_request) {
			log_notice("received signal [SIGHUP] -> reloading", 0);
			singleton<flared>::instance().reload();
			reload_request = 0;
		}

		vector<shared_connection> connection_list = this->_server->wait();

		if (reload_request) {
			log_notice("received signal [SIGHUP] -> reloading", 0);
			singleton<flared>::instance().reload();
			reload_request = 0;
		}

		vector<shared_connection>::iterator it;
		for (it = connection_list.begin(); it != connection_list.end(); it++) {
			shared_connection c = *it;

			if (this->_thread_pool->get_thread_size(thread_pool::thread_type_request) >= ini_option_object().get_max_connection()) {
				log_warning("too many connections [%d] -> closing socket and continue", ini_option_object().get_max_connection());
				continue;
			}

			stats_object->increment_total_connections();

			shared_thread t = this->_thread_pool->get(thread_pool::thread_type_request);
			if (t->get_id() == 0) {
				log_warning("too many threads (failed to create thread) [%d] -> closing socket and continue", this->_thread_pool->get_thread_size(thread_pool::thread_type_request));
				continue;
			}
			handler_request* h = _new_ handler_request(t, c);
			t->trigger(h);
		}
	}

	return 0;
}

/**
 *	flared application reload procs
 */
int flared::reload() {
	if (ini_option_object().reload() < 0) {
		log_notice("invalid config file -> skip reloading", 0);
		return -1;
	}

	// log_facility
	log_notice("re-opening syslog...", 0);
	singleton<logger>::instance().close();
	singleton<logger>::instance().open(this->_ident, ini_option_object().get_log_facility());

	// net_read_timeout
	connection::read_timeout = ini_option_object().get_net_read_timeout() * 1000;	// -> msec

	//  index_server_name
	this->_cluster->set_index_server_name(ini_option_object().get_index_server_name());

	//  index_server_port
	this->_cluster->set_index_server_port(ini_option_object().get_index_server_port());

	// reconstruction_interval
	this->_cluster->set_reconstruction_interval(ini_option_object().get_reconstruction_interval());

	// reconstruction_interval
	this->_cluster->set_reconstruction_interval(ini_option_object().get_reconstruction_interval());

	// reconstruction_bwlimit
	this->_cluster->set_reconstruction_bwlimit(ini_option_object().get_reconstruction_bwlimit());

	// replication_type
	this->_cluster->set_replication_type(ini_option_object().get_replication_type());
	
	// thread_pool_size
	this->_thread_pool->set_max_pool_size(ini_option_object().get_thread_pool_size());

	// max_total_thread_queue
	this->_cluster->set_max_total_thread_queue(ini_option_object().get_max_total_thread_queue());

	// re-setup resource limit (do not care about return value here)
	this->_set_resource_limit();

	// noreply_window_limit
	this->_cluster->set_noreply_window_limit(ini_option_object().get_noreply_window_limit());

	log_notice("process successfully reloaded", 0);

	return 0;
}

/**
 *	flared application shutdown procs
 */
int flared::shutdown() {
	log_notice("shutting down active, and pool threads...", 0);
	this->_thread_pool->shutdown();
	log_notice("all threads are successfully shutdown", 0);

	log_notice("closing storage...", 0);
	this->_storage->close();

	this->_clear_pid();

	return 0;
}
// }}}

// {{{ protected methods
string flared::_get_pid_path() {
	return ini_option_object().get_pid_path().empty() ?
					ini_option_object().get_data_dir() + "/" + this->_ident + ".pid" :
					ini_option_object().get_pid_path();
};
// }}}

// {{{ private methods
/**
 *	set resource limit
 */
int flared::_set_resource_limit() {
	struct rlimit rl;
	if (getrlimit(RLIMIT_NOFILE, &rl) < 0) {
		log_err("getrlimit() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	} else {
		rlim_t fd_limit = ini_option_object().get_max_connection() * 2 + 16;
		if (rl.rlim_cur < fd_limit) {
			rl.rlim_cur = fd_limit;
			if (rl.rlim_max < rl.rlim_cur) {
				rl.rlim_max = rl.rlim_cur;
			}
			if (setrlimit(RLIMIT_NOFILE, &rl) < 0) {
				log_err("setrlimit() failed: %s (%d) - please run as root", util::strerror(errno), errno);
				return -1;
			}
		}
		log_info("setting resource limit (RLIMIT_NOFILE): %d", fd_limit);
	}

	return 0;
}

/**
 *	setup signal handler(s)
 */
int flared::_set_signal_handler() {
	struct sigaction sa;

	// SIGTERM/SIGINT
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sa_term_handler;
	if (sigaction(SIGTERM, &sa, NULL) < 0) {
		log_err("sigaction for %d failed: %s (%d)", SIGTERM, util::strerror(errno), errno);
		return -1;
	}
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sa_term_handler;
	if (sigaction(SIGINT, &sa, NULL) < 0) {
		log_err("sigaction for %d failed: %s (%d)", SIGINT, util::strerror(errno), errno);
		return -1;
	}
	log_info("set up sigterm/sigint handler", 0);

	// SIGHUP
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sa_hup_handler;
	if (sigaction(SIGHUP, &sa, NULL) < 0) {
		log_err("sigaction for %d failed: %s (%d)", SIGHUP, util::strerror(errno), errno);
		return -1;
	}
	log_info("set up sighup handler", 0);

	// SIGUSR1
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sa_usr1_handler;
	if (sigaction(SIGUSR1, &sa, NULL) < 0) {
		log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
		return -1;
	}
	log_info("set up sigusr1 handler", 0);

	// signal mask
	sigset_t ss;
	sigfillset(&ss);
	sigdelset(&ss, SIGTERM);
	sigdelset(&ss, SIGINT);
	sigdelset(&ss, SIGHUP);
	if (sigprocmask(SIG_SETMASK, &ss, NULL) < 0) {
		log_err("sigprocmask() failed: %s (%d)", util::strerror(errno), errno);
	}

	return 0;
}
// }}}

}	// namespace flare
}	// namespace gree

// {{{ ::main (entry point)
int main(int argc, char **argv) {
	gree::flare::flared& f = gree::flare::singleton<gree::flare::flared>::instance();
	f.set_ident("flared");

	if (f.startup(argc, argv) < 0) {
		return -1;
	}
	int r = f.run();
	f.shutdown();

	return r;
}
// }}}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
