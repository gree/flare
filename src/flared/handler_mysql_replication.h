/**
 *	handler_mysql_replication.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __HANDLER_MYSQL_REPLICATION_H__
#define __HANDLER_MYSQL_REPLICATION_H__

#include "flared.h"

#ifdef ENABLE_MYSQL_REPLICATION

namespace gree {
namespace flare {

/**
 *	flare mysql_replication handler class
 */
class handler_mysql_replication : public thread_handler {
protected:

public:
	handler_mysql_replication(shared_thread t);
	virtual ~handler_mysql_replication();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif // ENABLE_MYSQL_REPLICATION

#endif // __HANDLER_MYSQL_REPLICATION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
