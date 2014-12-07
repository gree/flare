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
