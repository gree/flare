/**
 *	op_stats_manager.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __OP_STATS_MANAGER_H__
#define __OP_STATS_MANAGER_H__

#include <sstream>

#include "op_stats.h"

namespace gree {
namespace flare {

/**
 *	opcode text parser for manager application
 */
class op_stats_manager : public op_stats {
protected:

public:
	op_stats_manager(shared_connection c);
	virtual ~op_stats_manager();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif // __OP_STATS_MANAGER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
