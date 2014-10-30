/**
 *	handler_controller.h
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_CONTROLLER_H
#define	HANDLER_CONTROLLER_H

#include <string>

#include "thread_handler.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	monitor thread handler class
 */
class handler_controller : public thread_handler {
protected:
	cluster*						_cluster;

public:
	handler_controller(shared_thread t, cluster* cl);
	virtual ~handler_controller();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_CONTROLLER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
