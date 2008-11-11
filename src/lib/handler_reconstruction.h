/**
 *	handler_reconstruction.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__HANDLER_RECONSTRUCTION_H__
#define	__HANDLER_RECONSTRUCTION_H__

#include <string>

#include <boost/lexical_cast.hpp>

#include "connection.h"
#include "thread_handler.h"
#include "cluster.h"
#include "storage.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	reconstruction thread handler class
 */
class handler_reconstruction : public thread_handler {
protected:
	cluster*						_cluster;
	storage*						_storage;
	shared_connection		_connection;
	string							_node_server_name;
	int									_node_server_port;
	int									_partition;
	int									_partition_size;

public:
	handler_reconstruction(shared_thread t, cluster* cl, storage* st, string node_server_name, int node_server_port, int partition, int partition_size);
	virtual ~handler_reconstruction();

	virtual int run();

protected:
};

}	// namespace flare
}	// namespace gree

#endif	// __HANDLER_RECONSTRUCTION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
