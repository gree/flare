/**
 *	handler_mysql_replication.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef HANDLER_MYSQL_REPLICATION_H
#define HANDLER_MYSQL_REPLICATION_H

#include "flared.h"

#ifdef ENABLE_MYSQL_REPLICATION

namespace gree {
namespace flare {

/**
 *	flare mysql_replication handler class
 */
class handler_mysql_replication : public thread_handler {
protected:
	cluster*		_cluster;

public:
	handler_mysql_replication(shared_thread t, cluster* c);
	virtual ~handler_mysql_replication();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif // ENABLE_MYSQL_REPLICATION

#endif // HANDLER_MYSQL_REPLICATION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
