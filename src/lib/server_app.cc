/**
 *	server_app.cc
 *
 *	implementation of gree::flare::server_app
 *
 *	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
 *
 *	$Id$
 */
#include "server_app.h"

namespace gree {
namespace flare {

// {{{ static variables
volatile sig_atomic_t server_app::_sigusr1_flag = 0;
// }}}

// {{{ ctor/dtor
server_app::server_app():
		_shutdown_request(false),
		_reload_request(false) {
	
	// TODO: Added ABORT_IF_FAILURE() macro
	pthread_mutex_init(&this->_mutex_reload_request, NULL);
}

server_app::~server_app() {
}
// }}}

// {{{ protected methods
/**
 *	signal handling thread
 */
void* server_app::_signal_thread_run(void* p) {
	server_app* self = (server_app*) p;
	int sig;
	int result = 0;
	sigset_t waitset;

	pthread_detach(pthread_self());

	sigemptyset(&waitset);
	sigaddset(&waitset, SIGTERM);
	sigaddset(&waitset, SIGINT);
	sigaddset(&waitset, SIGHUP);

	if (pthread_sigmask(SIG_BLOCK, &waitset, NULL) < 0) {
		log_err("pthread_sigmask() failed: %s (%d)", util::strerror(errno), errno);
	}

	for (;;) {
		result = sigwait(&waitset, &sig);
		if (result == EINTR) {
			log_notice("sigwait() interrupted: %s (%d)", util::strerror(result), result);
			continue;
		} else if (result != 0) {
			log_err("sigwait() failed: %s (%d)", util::strerror(result), result);
			continue;
		}

		if (sig == SIGTERM || sig == SIGINT) {
			log_notice(
					"received signal [%s] -> requesting shutdown",
					sig == SIGTERM ? "SIGTERM" : "SIGINT");
			self->_shutdown_request = true;
			log_notice("sending [SIGUSR1] to thread_id:%u (main thread)", self->_main_thread_id);
			pthread_kill(self->_main_thread_id, SIGUSR1);
		} else if (sig == SIGHUP) {
			log_notice("received signal [SIGHUP] -> requesting reload", 0);

			// _reload_request requries mutex
			// because main thread read & modify this value atomically.
			pthread_mutex_lock(&self->_mutex_reload_request);
			self->_reload_request = true;
			pthread_mutex_unlock(&self->_mutex_reload_request);

			log_notice("sending [SIGUSR1] to thread_id:%u (main thread)", self->_main_thread_id);
			pthread_kill(self->_main_thread_id, SIGUSR1);
		} else {
			log_warning("unexpected signal (%d)", sig);
		}
	}

	return NULL;
}

/**
 * signal handler (SIGUSR1)
 * Needs to keep async-signal-safe.
 */
void server_app::_sa_usr1_handler(int sig) {
	server_app::_sigusr1_flag = 1;
}

/**
 *	setup signal handler(s)
 */
int server_app::_setup_signal_handler() {
	// SIGUSR1
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = server_app::_sa_usr1_handler;
	if (sigaction(SIGUSR1, &sa, NULL) < 0) {
		log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
		return -1;
	}
	log_info("set up sigusr1 handler", 0);

	// signal mask
	sigset_t ss;
	sigfillset(&ss);
	sigdelset(&ss, SIGUSR1);
	if (sigprocmask(SIG_SETMASK, &ss, NULL) < 0) {
		log_err("sigprocmask() failed: %s (%d)", util::strerror(errno), errno);
	}
	
	// start the signal handling thread
	if (pthread_create(&this->_signal_thread_id, NULL, server_app::_signal_thread_run, (void*)this) != 0) {
		log_err("failed to create signal handling thread.", 0);
		return -1;
	}

	return 0;
}

/**
 * reload if reload_request in main loop
 */
void server_app::_reload_if_requested() {
	pthread_mutex_lock(&this->_mutex_reload_request);
	if (this->_reload_request) {
		log_notice("reloading", 0);
		this->reload();

		// Reset signal flag
		this->_reload_request = false;
	}
	pthread_mutex_unlock(&this->_mutex_reload_request);
}

/**
 * log SIGUSR1 if sigusr1_flag in main loop
 */
void server_app::_sigusr1_flag_check() {
	if (!server_app::_sigusr1_flag)
		return;

	log_notice("received signal [SIGUSR1]. (This notice is logged with async. It might have received a long time ago.)", 0);
	server_app::_sigusr1_flag = 0;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
