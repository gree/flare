/**
 *	time_watcher_processor.h
 *
 *	@author	Yuya Yaguchi <yuya.yaguchi@gree.net>
 */
#ifndef	TIME_WATHCER_PROCESSOR_H
#define	TIME_WATHCER_PROCESSOR_H

#include "time_watcher.h"
#include "time_watcher_target_info.h"

namespace gree {
namespace flare {

class time_watcher;

class time_watcher_processor {
protected:
	time_watcher&                      _time_watcher;
	timespec                           _polling_interval;
	bool                               _shutdown_requested;
	pthread_mutex_t                    _mutex_shutdown_requested;
	pthread_cond_t                     _cond_shutdown_requested;

public:
	time_watcher_processor(
		time_watcher& time_watcher,
		timespec polling_interval
	);
	~time_watcher_processor();
	void operator()(); // Callable
	void request_shutdown();

protected:
	void _sleep_with_shutdown_request_wait();
};

}	// namespace flare
}	// namespace gree

#endif
