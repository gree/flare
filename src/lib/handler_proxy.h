/**
 *	handler_proxy.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__HANDLER_PROXY_H__
#define	__HANDLER_PROXY_H__

#include <string>

#include <boost/lexical_cast.hpp>

#include "connection.h"
#include "thread_handler.h"
#include "cluster.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	proxy thread handler class
 */
class handler_proxy : public thread_handler {
protected:
	cluster*						_cluster;
	shared_connection		_connection;
	string							_node_server_name;
	int									_node_server_port;
	int									_noreply_count;

public:
	handler_proxy(shared_thread t, cluster* cl, string node_server_name, int node_server_port);
	virtual ~handler_proxy();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif	// __HANDLER_PROXY_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
