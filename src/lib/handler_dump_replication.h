/**
 *	handler_dump_replication.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_DUMP_REPLICATION_H
#define	HANDLER_DUMP_REPLICATION_H

#include <string>

#include "connection.h"
#include "cluster.h"
#include "storage.h"
#include "thread_handler.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	thread handler class to replicate the dumped storage data
 **/
class handler_dump_replication : public thread_handler {
protected:
	cluster*									_cluster;
	storage*									_storage;
	const string							_replication_server_name;
	const int									_replication_server_port;
	int												_total_written;
	shared_connection					_connection;
	struct timeval						_prior_tv;

public:
	handler_dump_replication(shared_thread t, cluster* cl, storage* st, string server_name, int server_port);
	virtual ~handler_dump_replication();

	virtual int run();

protected:

private:
	long _sleep_for_bwlimit(int bytes_written, int bwlimit);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_DUMP_REPLICATION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
