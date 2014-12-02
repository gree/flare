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
