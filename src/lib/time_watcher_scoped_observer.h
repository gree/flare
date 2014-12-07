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
