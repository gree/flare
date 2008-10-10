/**
 *	stats_manager.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __STATS_MANAGER_H__
#define __STATS_MANAGER_H__

#include "stats.h"

namespace gree {
namespace flare {

/**
 *	stats class for flarem
 */
class stats_manager : public stats {
protected:

public:
	stats_manager();
	virtual ~stats_manager();
	virtual uint32_t get_curr_connections(thread_pool* tp);
};

}	// namespace flare
}	// namespace gree

#endif // __STATS_MANAGER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
