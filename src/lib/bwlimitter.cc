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
	if (bytes_written == 0) {
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