/**
 *	handler_reconstruction.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_RECONSTRUCTION_H
#define	HANDLER_RECONSTRUCTION_H

#include <string>

#include <boost/lexical_cast.hpp>

#include "connection.h"
#include "thread_handler.h"
#include "cluster.h"
#include "storage.h"

using namespace std;

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
	const string				_node_server_name;
	const int						_node_server_port;
	int									_partition;
	int									_partition_size;
	cluster::role				_role;
	int									_reconstruction_interval;
	int									_reconstruction_bwlimit;

public:
	handler_reconstruction(shared_thread t, cluster* cl, storage* st, string node_server_name, int node_server_port, int partition, int partition_size, cluster::role r, int reconstruction_interval, int reconstruction_bwlimit);
	virtual ~handler_reconstruction();

	virtual int run();

protected:
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_RECONSTRUCTION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
