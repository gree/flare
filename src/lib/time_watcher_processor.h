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
