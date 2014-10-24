/**
 *	handler_monitor.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_MONITOR_H
#define	HANDLER_MONITOR_H

#include <string>

#include <boost/lexical_cast.hpp>

#include "connection_tcp.h"
#include "thread_handler.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	monitor thread handler class
 */
class handler_monitor : public thread_handler {
protected:
	cluster*							_cluster;
	shared_connection_tcp	_connection;
	const string					_node_server_name;
	const int							_node_server_port;
	int										_monitor_threshold;
	int										_monitor_interval;
	int										_monitor_read_timeout;
	int										_down_state;

public:
	handler_monitor(shared_thread t, cluster* cl, string node_server_name, int node_server_port);
	virtual ~handler_monitor();

	virtual int run();

	int set_monitor_threshold(int monitor_threshold) { this->_monitor_threshold = monitor_threshold; return 0; };
	int set_monitor_interval(int monitor_interval) { this->_monitor_interval = monitor_interval; return 0; };
	int set_monitor_read_timeout(int monitor_read_timeout) { this->_monitor_read_timeout = monitor_read_timeout; return 0; };

protected:
	int _process_monitor();
	int _process_queue(shared_thread_queue q);

	int _down();
	int _up();
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_MONITOR_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
