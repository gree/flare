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
	static timespec msec_to_timespec(const uint32_t& msec);
	static timespec timeval_to_timespec(const timeval& val);
	static timespec get_time();
	static timespec sub(const timespec& a, const timespec& b);
	static bool is_bigger(const timespec& a, const timespec& b);
};

}	// namespace flare
}	// namespace gree

#endif	// TIME_UTIL_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
