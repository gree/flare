/**
 *	flared.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	FLARED_H
#define	FLARED_H

#include "app.h"
#include "ini_option.h"
#include "stats_node.h"

namespace gree {
namespace flare {

/**
 *	flared application class
 */
class flared : public app {
private:
	server*				_server;
	thread_pool*	_thread_pool;
	cluster*			_cluster;
	storage*			_storage;
#ifdef ENABLE_MYSQL_REPLICATION
	server*				_mysql_replication_server;
#endif

public:
	flared();
	~flared();

	int startup(int argc, char** argv);
	int run();
	int reload();
	int shutdown();

	thread_pool* get_thread_pool() { return this->_thread_pool; };
	cluster* get_cluster() { return this->_cluster; };
	storage* get_storage() { return this->_storage; };

protected:
	string _get_pid_path();

private:
	int _set_resource_limit();
	int _set_signal_handler();
};

}	// namespace flare
}	// namespace gree

#endif	// FLARED_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
