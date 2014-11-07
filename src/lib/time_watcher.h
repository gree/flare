/**
 *	time_watcher.h
 *
 *	@author	Yuya Yaguchi <yuya.yaguchi@gree.net>
 */
#ifndef	TIME_WATHCER_H
#define	TIME_WATHCER_H

#include <boost/function.hpp>
#include <boost/thread.hpp>
#include <map>
#include <stdint.h>
#include <pthread.h>
#include "time_watcher_processor.h"
#include "time_watcher_target_info.h"
#include "util.h"

using namespace std;

namespace gree {
namespace flare {

class time_watcher_processor;

class time_watcher {
public:
	typedef map<uint64_t, time_watcher_target_info> target_info_map;

protected:
	target_info_map                    _map;
	pthread_mutex_t                    _map_mutex;
	AtomicCounter                      _id_generator;
	bool                               _is_polling;
	boost::shared_ptr<time_watcher_processor> _processor;
	boost::shared_ptr<boost::thread>          _thread;

public:
	time_watcher();
	virtual ~time_watcher();
	uint64_t register_target(timespec threshold, boost::function<void(timespec)>);
	void unregister_target(uint64_t id);
	void check_timestamps();
	void start(uint32_t polling_interval_msec);
	void stop();

protected:
	void _check_timestamp(const time_watcher_target_info& info);
	uint64_t _generate_id();
};

}	// namespace flare
}	// namespace gree

#endif
