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
 *	time_watcher.h
 *
 *	@author	Yuya Yaguchi <yuya.yaguchi@gree.net>
 */
#include "storage_access_info.h"
#include "time_util.h"
#include "time_watcher.h"

namespace gree {
namespace flare {

time_watcher::time_watcher():
	_map(),
	_id_generator(0),
	_is_polling(false),
	_processor(),
	_thread() {
	pthread_mutex_init(&this->_map_mutex, NULL);
}

time_watcher::~time_watcher() {
}

void time_watcher::check_timestamps() {
	pthread_mutex_lock(&this->_map_mutex);
	for (
		time_watcher::target_info_map::const_iterator it = this->_map.begin();
		it != this->_map.end();
		it++
		) {
		this->_check_timestamp(it->second);
	}
	pthread_mutex_unlock(&this->_map_mutex);
}

uint64_t time_watcher::register_target(timespec threshold, boost::function<void(timespec)> callback) {
	time_watcher_target_info info;
	info.timestamp = time_util::get_time();
	info.threshold = threshold;
	info.callback = callback;
	pthread_mutex_lock(&this->_map_mutex);
	uint64_t id = this->_generate_id();
	this->_map[id] = info;
	pthread_mutex_unlock(&this->_map_mutex);
	return id;
}

void time_watcher::unregister_target(uint64_t id) {
	pthread_mutex_lock(&this->_map_mutex);
	this->_map.erase(id);
	pthread_mutex_unlock(&this->_map_mutex);
}

void time_watcher::start(uint32_t polling_interval_msec) {
	if (this->_is_polling) {
		log_err("a polling thread is still running.", 0);
		return;
	}
	this->_processor.reset(new time_watcher_processor(
		*this,
		time_util::msec_to_timespec(polling_interval_msec)
	));
	this->_thread.reset(new boost::thread(boost::ref(*this->_processor)));
	this->_is_polling = true;
}

void time_watcher::stop() {
	if (!this->_is_polling) {
		return;
	}
	this->_processor->request_shutdown();
	this->_thread->join();
	this->_thread.reset();
	this->_processor.reset();
	this->_is_polling = false;
}

void time_watcher::_check_timestamp(const time_watcher_target_info& info) {
	timespec now = time_util::get_time();
	timespec sub = time_util::sub(now, info.timestamp);
	if (time_util::is_bigger(sub, info.threshold)) {
		info.callback(sub);
	}
}

uint64_t time_watcher::_generate_id() {
	uint64_t id;
	do {
		id = this->_id_generator.incr();
	} while (this->_map.find(id) != this->_map.end());
	return id;
}

}	// namespace flare
}	// namespace gree
