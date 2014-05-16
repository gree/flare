/**
 *	handler_dump_replication.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	__HANDLER_DUMP_REPLICATION_H__
#define	__HANDLER_DUMP_REPLICATION_H__

#include "connection.h"
#include "cluster.h"
#include "storage.h"
#include "thread_handler.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	thread handler class to replicate the dumped storage data
 **/
class handler_dump_replication : public thread_handler {
protected:
	cluster*						_cluster;
	storage*						_storage;
	const string				_replication_server_name;
	const int						_replication_server_port;
	int									_partition;
	int									_partition_size;
	int									_wait;
	int									_bwlimit;
	shared_connection		_connection;
	int									_total_written;
	struct timeval			_prior_tv;

public:
	handler_dump_replication(shared_thread t, cluster* cl, storage* st, string server_name, int server_port, int partition, int partition_size, int bwlimit, int wait);
	virtual ~handler_dump_replication();

	virtual int run();

protected:

private:
	long _sleep_for_bwlimit(int bytes_written);
};

}	// namespace flare
}	// namespace gree

#endif	// __HANDLER_DUMP_REPLICATION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
