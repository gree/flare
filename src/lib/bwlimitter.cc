/*
 * Flare
 * --------------
 * Copyright (C) 1996-2001 Andrew Tridgell
 * Copyright (C) 1996 Paul Mackerras
 * Copyright (C) 2001, 2002 Martin Pool <mbp@samba.org>
 * Copyright (C) 2003, 2004, 2005, 2006 Wayne Davison
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

#include "bwlimitter.h"
#include <unistd.h>
#include "logger.h"
namespace gree {
namespace flare {

bwlimitter::bwlimitter():
	_bwlimit(0),
	_total_written(0) {
	this->_prior_tv.tv_sec = 0;
	this->_prior_tv.tv_usec = 0;
}

bwlimitter::~bwlimitter() {
}

// code from rsync 2.6.9
long bwlimitter::sleep_for_bwlimit(uint64_t bytes_written) {
	if (this->_bwlimit == 0 || bytes_written == 0) {
		return 0;
	}

	this->_total_written += bytes_written;

	static const long one_sec = 1000000L; // of microseconds in a second.

	long elapsed_usec;
	struct timeval start_tv;
	gettimeofday(&start_tv, NULL);
	if (this->_prior_tv.tv_sec) {
		elapsed_usec = (start_tv.tv_sec - this->_prior_tv.tv_sec) * one_sec
			+ (start_tv.tv_usec - this->_prior_tv.tv_usec);
		this->_total_written -= elapsed_usec * (long)this->_bwlimit / (one_sec/1024);
		if (this->_total_written < 0) {
			this->_total_written = 0;
		}
	}

	long sleep_usec = this->_total_written * (one_sec/1024) / this->_bwlimit;
	if (sleep_usec < one_sec / 10) {
		this->_prior_tv = start_tv;
		return 0;
	}

	usleep(sleep_usec);

	gettimeofday(&this->_prior_tv, NULL);
	elapsed_usec = (this->_prior_tv.tv_sec - start_tv.tv_sec) * one_sec
		+ (this->_prior_tv.tv_usec - start_tv.tv_usec);
	this->_total_written = (sleep_usec - elapsed_usec) * (long)this->_bwlimit / (one_sec/1024);

	return elapsed_usec;
}

}	// namespace flare
}	// namespace gree
