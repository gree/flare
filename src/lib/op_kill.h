/**
 *	op_kill.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_KILL_H__
#define	__OP_KILL_H__

#include <boost/lexical_cast.hpp>

#include "op.h"
#include "thread_pool.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (kill)
 */
class op_kill : public op {
protected:
	thread_pool*				_thread_pool;
	uint32_t						_id;

public:
	op_kill(shared_connection c, thread_pool* tp);
	virtual ~op_kill();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_KILL_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
