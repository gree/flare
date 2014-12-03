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
#include <stdint.h>
#include <boost/lexical_cast.hpp>

#include "connection_tcp.h"
#include "thread_handler.h"
#include "cluster.h"
#include "op_stats.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	monitor thread handler class
 */
class handler_monitor : public thread_handler {
protected:
	enum node_status {
		node_status_result_ok,
		node_status_result_ng,
		node_status_not_found,
	};

	cluster*							_cluster;
	shared_connection			_connection;
	const string					_node_server_name;
	const int							_node_server_port;
	int										_monitor_threshold;
	int										_monitor_interval;
	int										_monitor_read_timeout;
	int										_down_count;
	int										_node_map_version_mismatch_count;

public:
	enum tick_result {
		should_modify_state,
		keep_state,
	};

	handler_monitor(shared_thread t, cluster* cl, string node_server_name, int node_server_port);
	virtual ~handler_monitor();

	virtual int run();

	int set_monitor_threshold(int monitor_threshold) { this->_monitor_threshold = monitor_threshold; return 0; };
	int set_monitor_interval(int monitor_interval) { this->_monitor_interval = monitor_interval; return 0; };
	int set_monitor_read_timeout(int monitor_read_timeout) { this->_monitor_read_timeout = monitor_read_timeout; return 0; };

protected:
	virtual void _setup();
	void _mainloop();
	int _main();
	int _process_monitor();
	int _process_queue(shared_thread_queue q);
	void _process_node_map_version(const stats_results& results);
	void _update_node_map_version_match_count(uint64_t version);
	bool _is_node_map_version_mismatch_over_threshold();
	node_status _get_node_status(const stats_results& results);
	int _request_stats(stats_results& results);
	int _request_ping();
	virtual void _clear_read_buf();
	virtual int _down();
	virtual int _up();
	tick_result _tick_down();
	tick_result _tick_up();
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_MONITOR_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
