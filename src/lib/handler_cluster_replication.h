/**
 *	handler_cluster_replication.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	__HANDLER_CLUSTER_REPLICATION_H__
#define	__HANDLER_CLUSTER_REPLICATION_H__

#include "connection.h"
#include "cluster.h"
#include "thread_handler.h"
#include "thread_queue.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	inter-cluster replication thread handler class
 */
class handler_cluster_replication : public thread_handler {
protected:
	cluster*						_cluster;
	string							_replication_server_name;
	int									_replication_server_port;
	shared_connection		_connection;

public:
	handler_cluster_replication(shared_thread t, cluster* c, string server_name, int server_port);
	virtual ~handler_cluster_replication();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif	// __HANDLER_CLUSTER_REPLICATION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
