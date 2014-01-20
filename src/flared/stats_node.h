/**
 *	stats_node.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef STATS_NODE_H
#define STATS_NODE_H

#include "stats.h"

namespace gree {
namespace flare {

/**
 *	stats class for flarem
 */
class stats_node : public stats {
protected:

public:
	stats_node();
	virtual ~stats_node();
	virtual uint32_t get_curr_connections(thread_pool* tp);
};

}	// namespace flare
}	// namespace gree

#endif // STATS_NODE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
