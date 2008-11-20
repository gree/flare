/**
 *	queue_update_monitor_option.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__QUEUE_UPDATE_MONITOR_OPTION_H__
#define	__QUEUE_UPDATE_MONITOR_OPTION_H__

#include "mm.h"
#include "logger.h"
#include "util.h"
#include "thread_queue.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

typedef class queue_update_monitor_option queue_update_monitor_option;
typedef shared_ptr<queue_update_monitor_option> shared_queue_update_monitor_option;

/**
 *	monitor option update queue class
 */
class queue_update_monitor_option : public thread_queue {
protected:
	int			_monitor_threshold;
	int			_monitor_interval;
	int			_monitor_read_timeout;

public:
	queue_update_monitor_option(int monitor_threshold, int monitor_inteval, int monitor_read_timeout);
	virtual ~queue_update_monitor_option();

	int get_monitor_threshold() { return this->_monitor_threshold; };
	int get_monitor_interval() { return this->_monitor_interval; };
	int get_monitor_read_timeout() { return this->_monitor_read_timeout; };
};

}	// namespace flare
}	// namespace gree

#endif	// __QUEUE_UPDATE_MONITOR_OPTION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
