/**
 *	queue_update_monitor_interval.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__QUEUE_UPDATE_MONITOR_INTERVAL_H__
#define	__QUEUE_UPDATE_MONITOR_INTERVAL_H__

#include "mm.h"
#include "logger.h"
#include "util.h"
#include "thread_queue.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

typedef class queue_update_monitor_interval queue_update_monitor_interval;
typedef shared_ptr<queue_update_monitor_interval> shared_queue_update_monitor_interval;

/**
 *	monitor interval update queue class
 */
class queue_update_monitor_interval : public thread_queue {
protected:
	int			_monitor_interval;

public:
	queue_update_monitor_interval(int monitor_inteval);
	virtual ~queue_update_monitor_interval();

	int get_monitor_interval() { return this->_monitor_interval; };
};

}	// namespace flare
}	// namespace gree

#endif	// __QUEUE_UPDATE_MONITOR_INTERVAL_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
