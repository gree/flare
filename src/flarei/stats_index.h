/**
 *	stats_index.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef STATS_INDEX_H
#define STATS_INDEX_H

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

#endif // STATS_INDEX_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
