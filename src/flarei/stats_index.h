/**
 *	stats_index.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __STATS_INDEX_H__
#define __STATS_INDEX_H__

#include "stats.h"

namespace gree {
namespace flare {

/**
 *	stats class for flarei
 */
class stats_index : public stats {
protected:

public:
	stats_index();
	virtual ~stats_index();
	virtual uint32_t get_curr_connections(thread_pool* tp);
};

}	// namespace flare
}	// namespace gree

#endif // __STATS_INDEX_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
