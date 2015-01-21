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
 *	time_util.cc
 *
 *	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
 *
 *	$Id$
 */
#include "time_util.h"
#include "config.h"

namespace gree {
namespace flare {

const long time_util_billion = 1000000000;

timespec time_util::msec_to_timespec(const uint32_t& msec) {
	timespec t;
	t.tv_sec = msec / 1000;
	t.tv_nsec = (msec - t.tv_sec * 1000) * 1000 * 1000;
	return t;
}

timespec time_util::timeval_to_timespec(const timeval &val) {
	timespec spec;
	spec.tv_sec = val.tv_sec;
	spec.tv_nsec = val.tv_usec * 1000;
	return spec;
}

/**
 * Return the current time stamp.
 *
 * The time returned by this function should not jump forwards and backwards.
 * So we use clock_gettime() with CLOCK_MONOTONIC option if available.
 * The time would be affected by the adjustment of NTP,
 * even if it is called with CLOCK_MONOTONIC option,
 * but the slew rate is limited to 0.5 ms/s. Generally no problem.
 */
timespec time_util::get_time(clock clk) {
	timespec t;
#ifdef HAVE_CLOCK_GETTIME
	clockid_t clock_id;
	switch (clk) {
	case clock_monotonic:
		clock_id = CLOCK_MONOTONIC;
		break;
	case clock_realtime:
		clock_id = CLOCK_REALTIME;
		break;
	}
	clock_gettime(clock_id, &t);
#else
	timeval val;
	gettimeofday(&val, NULL);
	t = timeval_to_timespec(val);
#endif
	return t;
}

timespec time_util::add(const timespec &a, const timespec &b) {
	timespec result;
	result.tv_sec = a.tv_sec + b.tv_sec;
	result.tv_nsec = a.tv_nsec + b.tv_nsec;
	if (result.tv_nsec >= time_util_billion) {
		result.tv_nsec -= time_util_billion;
		++result.tv_sec;
	}
	return result;
}

timespec time_util::sub(const timespec &a, const timespec &b) {
	timespec result;
	result.tv_sec = a.tv_sec - b.tv_sec;
	result.tv_nsec = a.tv_nsec - b.tv_nsec;
	if (result.tv_nsec < 0) {
		--result.tv_sec;
		result.tv_nsec += time_util_billion;
	}
	return result;
}

bool time_util::is_bigger(const timespec &a, const timespec &b) {
	return a.tv_sec == b.tv_sec
		? a.tv_nsec > b.tv_nsec
		: a.tv_sec > b.tv_sec;
}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
