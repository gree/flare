/**
*	time_watcher_scoped_observer.h
*
*	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
*
*	$Id$
*/

#ifndef	TIME_WATCHER_SCOPED_OBSERVER_H
#define	TIME_WATCHER_SCOPED_OBSERVER_H

#include <stdint.h>
#include "storage_access_info.h"

namespace gree {
namespace flare {

class time_watcher_scoped_observer {
protected:
	uint64_t _tw_id;

public:
	time_watcher_scoped_observer(storage_access_info info);
	virtual ~time_watcher_scoped_observer();
};

}	// namespace flare
}	// namespace gree

#endif