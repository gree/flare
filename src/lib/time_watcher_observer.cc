/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
/**
 *	time_watcher_observer.cc
 *
 *	@author	Yuya Yaguchi <yuya.yaguchi@gree.net>
 */
#include "app.h"
#include "logger.h"
#include "time_util.h"
#include "time_watcher.h"
#include "time_watcher_observer.h"

namespace gree {
namespace flare {

timespec time_watcher_observer::_threshold_warn = {0, 0};
timespec time_watcher_observer::_threshold_ping_ng = {0, 0};
storage_listener* time_watcher_observer::_storage_listener = NULL;

/*
 * This function will be called on the time_watcher thread.
 * Be careful to avoid block the thread.
 */
void time_watcher_observer::on_storage_access_no_response(const timespec& difference, const storage_access_info& additional_info) {
	if (time_util::is_bigger(difference, time_watcher_observer::_threshold_ping_ng)) {
		log_err(
			"thread (id: %lu, thread_id: %lu) running too long time: %u.%9u sec",
			additional_info.thread->get_id(),
			additional_info.thread->get_thread_id(),
			difference.tv_sec,
			difference.tv_nsec
		);

		time_watcher_observer::_storage_listener->on_storage_error();
		return;
	}

	log_warning(
		"thread (id: %lu, thread_id: %lu) running too long time: %u.%6u sec",
		additional_info.thread->get_id(),
		additional_info.thread->get_thread_id(),
		difference.tv_sec,
		difference.tv_nsec
	);
}

uint64_t time_watcher_observer::register_on_storage_access_no_response_callback(storage_access_info info) {
	return time_watcher_object->register_target(
		time_watcher_observer::_threshold_warn,
		boost::bind(&time_watcher_observer::on_storage_access_no_response, boost::placeholders::_1, info)
	);
}

void time_watcher_observer::unregister(uint64_t id) {
	time_watcher_object->unregister_target(id);
}

void time_watcher_observer::set_threshold_warn_msec(uint32_t msec) {
	time_watcher_observer::_threshold_warn = time_util::msec_to_timespec(msec);
}

void time_watcher_observer::set_threshold_ping_ng_msec(uint32_t msec) {
	time_watcher_observer::_threshold_ping_ng = time_util::msec_to_timespec(msec);
}

void time_watcher_observer::set_storage_listener(storage_listener* listener) {
	time_watcher_observer::_storage_listener = listener;
}

}	// namespace flare
}	// namespace gree
