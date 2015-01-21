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
 *	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
 *
 *	$Id$
 */

#ifndef	BWLIMITTER_H
#define	BWLIMITTER_H

#include <stdint.h>
#include <sys/time.h>

namespace gree {
namespace flare {

class bwlimitter {
protected:
	uint64_t _bwlimit;
	int64_t _total_written;
	struct timeval _prior_tv;

public:
	bwlimitter();
	virtual ~bwlimitter();
	long sleep_for_bwlimit(uint64_t bytes_written);
	uint64_t get_bwlimit() { return _bwlimit; }
	void set_bwlimit(uint64_t bwlimit) { _bwlimit = bwlimit; }
};

}	// namespace flare
}	// namespace gree

#endif
