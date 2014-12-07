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
