/**
 *	app.cc
 *
 *	implementation of gree::flare::app (and some other global stuffs)
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"

namespace gree {
namespace flare {

// {{{ global functions/variables
stats* stats_object = NULL;
// }}}

// {{{ ctor/dtor
/**
 *	ctor for app
 */
app::app():
		_ident(""),
		_pid(0),
		_pid_path(""),
		_shutdown_request(false) {
}

/**
 *	dtor for app
 */
app::~app() {
	if (stats_object != NULL) {
		_delete_(stats_object);
		stats_object = NULL;
	}
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	application startup procs
 */
int app::startup(int argc, char **argv) {
	stats_object = _new_ stats();
	stats_object->startup();

	this->_set_pid();

	return 0;
}

/**
 *	application running loop
 */
int app::run() {
	return 0;
}

/**
 *	application reload procs
 */
int app::reload() {
	return 0;
}

/**
 *	application shutdown procs
 */
int app::shutdown() {
	this->_clear_pid();

	return 0;
}
// }}}

// {{{ protected methods
/**
 *	daemonize
 */
int app::_daemonize() {
	log_debug("daemonize process is requested -> fork()", 0);
	switch (fork()) {
	case 0:
		log_notice("daemon process created -> now i have new pid [%d]", getpid());
		break;
	case -1:
		log_err("fork() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	default:
		log_debug("parent process exiting...", 0);
		exit(0);
	}

	if (setsid() < 0) {
		return -1;
	}

	close(0);
	close(1);
	close(2);
	open("/dev/null", O_RDWR);
	dup2(0, 1);
	dup2(0, 2);

	return 0;
}

/**
 *	check and log pid
 */
int app::_set_pid() {
	pid_t pid = getpid();
	string pid_path = this->_get_pid_path();

	// check if another process exists
	ifstream ifs(pid_path.c_str());
	if (ifs.fail() == false) {
		string s;
		ifs >> s;
		pid_t pid_current = lexical_cast<pid_t>(s);
		if (kill(pid_current, 0) < 0 && errno == ESRCH) {
			log_info("logged pid [%d] seems not to exist (%s) -> ignoring", pid_current, util::strerror(errno));
		} else {
			// seems to another process exists
			log_info("another process seems exist [%d] -> exiting", pid_current);
			return -1;
		}
	}
	ifs.close();

	ofstream ofs(pid_path.c_str());
	if (ofs.fail()) {
		log_err("setting pid failed [%s]", pid_path.c_str());
		ofs.close();
		return -1;
	}
	ofs << pid << endl;
	ofs.close();

	this->_pid = pid;
	log_info("setting pid file [%s]", pid_path.c_str());

	return 0;
}

/**
 *	clear logged pid
 */
int app::_clear_pid() {
	string pid_path = this->_get_pid_path();
	if (unlink(pid_path.c_str()) < 0) {
		log_err("unlink(%s) failed: %s (%d)", pid_path.c_str(), util::strerror(errno), errno);
		return -1;
	}
	log_info("clearing pid file [%s]", pid_path.c_str());

	return 0;
}

string app::_get_pid_path() {
	return this->_ident + ".pid";
};
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
