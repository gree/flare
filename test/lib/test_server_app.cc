/**
*	test_server_app.cc
*
*	@author Yuya YAGUCHI <yuya.yaguchi@gree.net>
*/

#include <cppcutter.h>
#include <server_app.h>

using namespace gree::flare;

namespace test_server_app {
class server_app_test : public server_app {
public:
	int startup(int argc, char **argv) {
		if (server_app::startup(argc, argv) < 0) {
			return -1;
		};
		this->_main_thread_id = pthread_self();
		if (this->_startup_signal_handler() < 0) {
			return -1;
		}
		return 0;
	}

	int shutdown() {
		if (this->_shutdown_signal_handler() < 0) {
			return -1;
		}
		if (server_app::shutdown() < 0) {
			return -1;
		};
		return 0;
	}

	void set_shutdown_request(bool a) {
		this->_shutdown_requested = a;
	}

	void set_reload_request(bool a) {
		this->_reload_requested = a;
	}

	void set_sigusr1_flag(sig_atomic_t a) {
		this->_sigusr1_flag = a;
	}

	bool get_shutdown_request() {
		return this->_shutdown_requested;
	}

	bool get_reload_request() {
		return this->_reload_requested;
	}

	sig_atomic_t get_sigusr1_flag() {
		return this->_sigusr1_flag;
	}

	pthread_t get_signal_thread_id() {
		return this->_signal_thread_id;
	}
};


server_app_test* app;
timespec t = {0, 1000000};
struct sigaction	prev_sigusr1_action;

void setup() {
	if (sigaction(SIGUSR1, NULL, &prev_sigusr1_action) < 0) {
		log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
	}

	app = new server_app_test();
	cut_assert_equal_int(app->startup(0, NULL), 0);
}

void teardown() {
	cut_assert_equal_int(app->shutdown(), 0);
	delete app;
	sigaction(SIGUSR1, NULL, NULL);

	if (sigaction(SIGUSR1, &prev_sigusr1_action, NULL) < 0) {
		log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
		return;
	}
}

void test_server_app_sigterm_handling() {
	app->set_shutdown_request(false);
	app->set_reload_request(false);
	nanosleep(&t, NULL);
	kill(getpid(), SIGTERM);
	nanosleep(&t, NULL);
	cut_assert_true(app->get_shutdown_request());
	cut_assert_false(app->get_reload_request());
}

void test_server_app_sigint_handling() {
	app->set_shutdown_request(false);
	app->set_reload_request(false);
	nanosleep(&t, NULL);
	kill(getpid(), SIGINT);
	nanosleep(&t, NULL);
	cut_assert_true(app->get_shutdown_request());
	cut_assert_false(app->get_reload_request());
}

void test_server_app_sighup_handling() {
	app->set_shutdown_request(false);
	app->set_reload_request(false);
	nanosleep(&t, NULL);
	kill(getpid(), SIGHUP);
	nanosleep(&t, NULL);
	cut_assert_false(app->get_shutdown_request());
	cut_assert_true(app->get_reload_request());

	// handler accept SIGHUP multiple times.
	app->set_shutdown_request(false);
	app->set_reload_request(false);
	nanosleep(&t, NULL);
	kill(getpid(), SIGHUP);
	nanosleep(&t, NULL);
	cut_assert_false(app->get_shutdown_request());
	cut_assert_true(app->get_reload_request());

	app->set_shutdown_request(false);
	app->set_reload_request(false);
	nanosleep(&t, NULL);
	kill(getpid(), SIGHUP);
	nanosleep(&t, NULL);
	cut_assert_false(app->get_shutdown_request());
	cut_assert_true(app->get_reload_request());
}

void test_server_app_sigusr1_handling() {
	app->set_sigusr1_flag(0);
	kill(getpid(), SIGUSR1);
	cut_assert_equal_int(app->get_sigusr1_flag(), 1);

	app->set_sigusr1_flag(0);
	kill(getpid(), SIGUSR1);
	kill(getpid(), SIGUSR1);
	cut_assert_equal_int(app->get_sigusr1_flag(), 1);
}

}
