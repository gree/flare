/**
*	time_watcher_scoped_observer.cc
*
*	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
*
*	$Id$
*/

#include "time_watcher_scoped_observer.h"
#include "time_watcher_observer.h"

namespace gree {
namespace flare {

time_watcher_scoped_observer::time_watcher_scoped_observer(storage_access_info info) {
	this->_tw_id = time_watcher_observer::register_on_storage_access_no_response_callback(info);
}

time_watcher_scoped_observer::~time_watcher_scoped_observer() {
	time_watcher_observer::unregister(this->_tw_id);
}

}	// namespace flare
}	// namespace gree