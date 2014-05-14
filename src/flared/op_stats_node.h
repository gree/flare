/**
 *	op_stats_node.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef OP_STATS_NODE_H
#define OP_STATS_NODE_H

#include <sstream>

#include "op_stats.h"

namespace gree {
namespace flare {

/**
 *	opcode class (stats)
 */
class op_stats_node : public op_stats {
protected:

public:
	op_stats_node(shared_connection c);
	virtual ~op_stats_node();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif // OP_STATS_NODE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
