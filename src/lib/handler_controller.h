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
 *	handler_controller.h
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#ifndef	HANDLER_CONTROLLER_H
#define	HANDLER_CONTROLLER_H

#include <string>

#include "thread_handler.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	monitor thread handler class
 */
class handler_controller : public thread_handler {
protected:
	cluster*						_cluster;

public:
	handler_controller(shared_thread t, cluster* cl);
	virtual ~handler_controller();

	virtual int run();

protected:
	int _process_queue(shared_thread_queue q);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_CONTROLLER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
