/**
 *	app.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	APP_H
#define	APP_H

#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <iterator>
#include <vector>
#include <map>
#include <queue>

#include <boost/algorithm/string.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/regex.hpp>
#include <boost/shared_ptr.hpp>
#include <boost/tokenizer.hpp>

#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>

#include "config.h"
#include "singleton.h"
#include "logger.h"
#include "util.h"
#include "connection.h"
#include "server.h"
#include "client.h"
#include "stats.h"
#include "status.h"
#include "thread_pool.h"
#include "op.h"
#include "cluster.h"
#include "storage.h"
#include "storage_tch.h"
#include "storage_tcb.h"
#ifdef HAVE_LIBKYOTOCABINET
#include "storage_kch.h"
#endif

using namespace std;

namespace gree {
namespace flare {

extern stats* stats_object;
extern status* status_object;

/**
 *	application base class
 */
class app {
protected:
	string				_ident;
	pid_t					_pid;
	string				_pid_path;
	bool					_shutdown_request;

public:
	app();
	virtual ~app();

	virtual int startup(int argc, char **argv);
	virtual int run();
	virtual int reload();
	virtual int shutdown();

	int request_shutdown() { this->_shutdown_request = true; return 0; };

	int set_ident(string ident) { this->_ident = ident; return 0; };
	string get_ident() { return this->_ident; };
	pid_t get_pid() { return this->_pid; };

protected:
	int _daemonize();
	int _set_pid();
	int _clear_pid();

	virtual string _get_pid_path();
};

}	// namespace flare
}	// namespace gree

#endif	// APP_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
