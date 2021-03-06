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
 *	queue_update_monitor_option.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	QUEUE_UPDATE_MONITOR_OPTION_H
#define	QUEUE_UPDATE_MONITOR_OPTION_H

#include "logger.h"
#include "util.h"
#include "thread_queue.h"

using namespace std;

namespace gree {
namespace flare {

typedef class queue_update_monitor_option queue_update_monitor_option;
typedef boost::shared_ptr<queue_update_monitor_option> shared_queue_update_monitor_option;

/**
 *	monitor option update queue class
 */
class queue_update_monitor_option : public thread_queue {
protected:
	int			_monitor_threshold;
	int			_monitor_interval;
	int			_monitor_read_timeout;

public:
	queue_update_monitor_option(int monitor_threshold, int monitor_inteval, int monitor_read_timeout);
	virtual ~queue_update_monitor_option();

	int get_monitor_threshold() { return this->_monitor_threshold; };
	int get_monitor_interval() { return this->_monitor_interval; };
	int get_monitor_read_timeout() { return this->_monitor_read_timeout; };
};

}	// namespace flare
}	// namespace gree

#endif	// QUEUE_UPDATE_MONITOR_OPTION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
