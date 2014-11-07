#ifndef	TIME_WATHCER_TARGET_INFO_H
#define	TIME_WATHCER_TARGET_INFO_H

#include <time.h>
#include <boost/function.hpp>

namespace gree {
namespace flare {

class time_watcher_target_info {
public:
	timespec timestamp;
	timespec threshold;

	// This function will be called on the time_watcher thread.
	// Be careful to avoid block the thread.
	boost::function<void(timespec)> callback;
};

}	// namespace flare
}	// namespace gree

#endif
