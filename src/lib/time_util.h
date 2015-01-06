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
 *	time_util.h
 *
 *	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
 *
 *	$Id$
 */
#ifndef	TIME_UTIL_H
#define	TIME_UTIL_H

#include <sys/time.h>
#include <time.h>
#include <stdint.h>

namespace gree {
namespace flare {

class time_util {
public:
	enum clock {
		clock_monotonic,
		clock_realtime,
	};

	static timespec msec_to_timespec(const uint32_t& msec);
	static timespec timeval_to_timespec(const timeval& val);
	static timespec get_time(clock clk = clock_monotonic);
	static timespec add(const timespec& a, const timespec& b);
	static timespec sub(const timespec& a, const timespec& b);
	static bool is_bigger(const timespec& a, const timespec& b);
};

}	// namespace flare
}	// namespace gree

#endif	// TIME_UTIL_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
