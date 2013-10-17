/**
 *	flarei.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__FLAREI_H__
#define	__FLAREI_H__

#include "app.h"
#include "handler_alarm.h"
#include "handler_request.h"
#include "handler_controller.h"
#include "ini_option.h"
#include "stats_index.h"

namespace gree {
namespace flare {

/**
 *	flarei application class
 */
class flarei : public app {
private:
	server*				_server;
	thread_pool*	_thread_pool;
	cluster*			_cluster;

public:
	flarei();
	~flarei();

	int startup(int argc, char** argv);
	int run();
	int reload();
	int shutdown();

	thread_pool* get_thread_pool() { return this->_thread_pool; };
	cluster* get_cluster() { return this->_cluster; };

protected:
	string _get_pid_path();

private:
	int _set_resource_limit();
	int _set_signal_handler();
};

}	// namespace flare
}	// namespace gree

#endif	// __FLAREI_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
