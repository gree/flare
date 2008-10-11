/**
 *	cluster.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__CLUSTER_H__
#define	__CLUSTER_H__

#include <boost/regex.hpp>

#include "connection.h"
#include "thread_pool.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	cluster class
 */
class cluster {
public:
	enum							type {
		type_index,
		type_node,
	};

	enum							state {
		state_master,
		state_slave,
		state_proxy,
	};

protected:
	thread_pool*			_thread_pool;
	type							_type;
	state							_state;

	// node
	string						_index_server_name;
	int								_index_server_port;

public:
	cluster(thread_pool* tp);
	virtual ~cluster();

	int startup_index();
	int startup_node(string index_server_name, int index_server_port);

	string get_index_server_name() { return this->_index_server_name; };
	int get_index_server_port() { return this->_index_server_port; };
};

}	// namespace flare
}	// namespace gree

#endif	// __CLUSTER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
