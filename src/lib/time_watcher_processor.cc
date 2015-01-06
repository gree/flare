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
 *	time_watcher_processor.cc
 *
 *	@author	Yuya Yaguchi <yuya.yaguchi@gree.net>
 */

// order is important. to avoid conflict gree::flare::thread and boost::thread.
#include "storage_access_info.h"

#include "time_watcher_processor.h"
#include "logger.h"
#include "time_util.h"

namespace gree {
namespace flare {

time_watcher_processor::time_watcher_processor(
	time_watcher& time_watcher,
	timespec polling_interval
):
		_time_watcher(time_watcher),
		_polling_interval(polling_interval),
		_shutdown_requested(false) {
	pthread_mutex_init(&this->_mutex_shutdown_requested, NULL);
	pthread_cond_init(&this->_cond_shutdown_requested, NULL);
}

time_watcher_processor::~time_watcher_processor() {
	pthread_mutex_destroy(&this->_mutex_shutdown_requested);
	pthread_cond_destroy(&this->_cond_shutdown_requested);
}

void time_watcher_processor::operator()()
{
	for(;;) {
		if (this->_shutdown_requested) {
			log_info("thread shutdown request -> breaking loop", 0);
			break;
		}
		if (this->_polling_interval.tv_sec == 0 &&
				this->_polling_interval.tv_nsec == 0) {
			log_info("thread watch disabled -> breaking loop", 0);
			break;
		}
		this->_time_watcher.check_timestamps();

		this->_sleep_with_shutdown_request_wait();
	}
}

void time_watcher_processor::request_shutdown() {
	pthread_mutex_lock(&this->_mutex_shutdown_requested);
	this->_shutdown_requested = true;
	pthread_cond_signal(&this->_cond_shutdown_requested);
	pthread_mutex_unlock(&this->_mutex_shutdown_requested);
}

void time_watcher_processor::_sleep_with_shutdown_request_wait() {
	pthread_mutex_lock(&this->_mutex_shutdown_requested);
	if (this->_shutdown_requested == false) {
		timespec sleep_until = time_util::add(time_util::get_time(time_util::clock_realtime), this->_polling_interval);
		pthread_cond_timedwait(&this->_cond_shutdown_requested, &this->_mutex_shutdown_requested, &sleep_until);
	}
	pthread_mutex_unlock(&this->_mutex_shutdown_requested);
}

}	// namespace flare
}	// namespace gree
