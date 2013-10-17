/**
 *	handler_controller.h
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#ifndef	__HANDLER_CONTROLLER_H__
#define	__HANDLER_CONTROLLER_H__

#include <string>

#include "thread_handler.h"
#include "cluster.h"

using namespace std;
using namespace boost;

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

#endif	// __HANDLER_CONTROLLER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
