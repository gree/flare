/**
 *	handler_proxy.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_PROXY_H
#define	HANDLER_PROXY_H

#include <string>

#include <boost/lexical_cast.hpp>

#include "connection.h"
#include "thread_handler.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	proxy thread handler class
 */
class handler_proxy : public thread_handler {
protected:
	cluster*						_cluster;
	shared_connection		_connection;
	const string				_node_server_name;
	const int						_node_server_port;
	int									_noreply_count;
	bool								_skip_proxy;

public:
	handler_proxy(shared_thread t, cluster* cl, string node_server_name, int node_server_port);
	virtual ~handler_proxy();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_PROXY_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
