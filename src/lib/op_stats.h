/**
 *	op_stats.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_STATS_H__
#define	__OP_STATS_H__

#include <sstream>
#include <string>

#include "op.h"
#include "thread_pool.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (stats)
 */
class op_stats : public op {
protected:
	enum			stats_type {
		stats_type_error = -1,
		stats_type_default,
		stats_type_items,
		stats_type_slabs,
		stats_type_sizes,
		stats_type_threads,
		stats_type_threads_request,
	};

	stats_type	_stats_type;

public:
	op_stats(shared_connection c);
	virtual ~op_stats();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();

	virtual int _send_stats(thread_pool* tp);
	virtual int _send_stats_items();
	virtual int _send_stats_slabs();
	virtual int _send_stats_sizes();
	virtual int _send_stats_threads(thread_pool* tp);
	virtual int _send_stats_threads(thread_pool* tp, int type);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_STATS_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
