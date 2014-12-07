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
 *	time_watcher_observer.h
 *
 *	@author	Yuya Yaguchi <yuya.yaguchi@gree.net>
 */
#ifndef	TIME_WATHCER_OBSERVER_H
#define	TIME_WATHCER_OBSERVER_H

#include <stdint.h>
#include <sys/time.h>
#include "storage_access_info.h"
#include "storage_listener.h"

namespace gree {
namespace flare {

class storage_access_info;

class time_watcher_observer {
protected:
	static timespec           _threshold_warn;
	static timespec           _threshold_ping_ng;
	static storage_listener* _storage_listener;

public:
	static void on_storage_access_no_response(const timespec& difference, const storage_access_info& additional_info);
	static uint64_t register_on_storage_access_no_response_callback(storage_access_info info);
	static void unregister(uint64_t id);
	static void set_threshold_warn_msec(uint32_t msec);
	static void set_threshold_ping_ng_msec(uint32_t msec);
	static void set_storage_listener(storage_listener* listener);
};

}	// namespace flare
}	// namespace gree

#endif
