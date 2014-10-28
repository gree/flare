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
		this->_main_thread_id = pthread_self();
		if (this->_startup_signal_handler() < 0) {
			return -1;
		}
		return 0;
	}

	int shutdown() {
		if (server_app::shutdown()) {
			return -1;
		}
		if (this->_shutdown_signal_handler()) {
			return -1;
		}
		return 0;
	}

	int startup_signal_handler() {
		return server_app::_startup_signal_handler();
	}

	int shutdown_signal_handler() {
		return server_app::_shutdown_signal_handler();
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

void test_server_app_signal_thread() {
	server_app_test app;
	timespec t = {0, 1000000};

	cut_assert_equal_int(app.startup(0, NULL), 0);

	app.set_shutdown_request(false);
	app.set_reload_request(false);
	nanosleep(&t, 0);
	kill(getpid(), SIGTERM);
	nanosleep(&t, 0);
	cut_assert_true(app.get_shutdown_request());
	cut_assert_false(app.get_reload_request());
	cut_assert_equal_int(app.shutdown_signal_handler(), 0);

	cut_assert_equal_int(app.startup_signal_handler(), 0);
	app.set_shutdown_request(false);
	app.set_reload_request(false);
	nanosleep(&t, 0);
	kill(getpid(), SIGINT);
	nanosleep(&t, 0);
	cut_assert_true(app.get_shutdown_request());
	cut_assert_false(app.get_reload_request());
	cut_assert_equal_int(app.shutdown_signal_handler(), 0);

	cut_assert_equal_int(app.startup_signal_handler(), 0);
	app.set_shutdown_request(false);
	app.set_reload_request(false);
	nanosleep(&t, 0);
	kill(getpid(), SIGHUP);
	nanosleep(&t, 0);
	cut_assert_false(app.get_shutdown_request());
	cut_assert_true(app.get_reload_request());

	cut_assert_equal_int(app.shutdown(), 0);
}

void test_server_app_sigusr1_handling() {
	server_app_test app;
	cut_assert_equal_int(app.startup(0, NULL), 0);

	app.set_sigusr1_flag(0);
	kill(getpid(), SIGUSR1);
	cut_assert_equal_int(app.get_sigusr1_flag(), 1);

	app.set_sigusr1_flag(0);
	kill(getpid(), SIGUSR1);
	kill(getpid(), SIGUSR1);
	cut_assert_equal_int(app.get_sigusr1_flag(), 1);

	cut_assert_equal_int(app.shutdown(), 0);
}


}