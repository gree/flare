/**
 *	op_kill.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_KILL_H
#define	OP_KILL_H

#include <boost/lexical_cast.hpp>

#include "op.h"
#include "thread_pool.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (kill)
 */
class op_kill : public op {
protected:
	thread_pool*				_thread_pool;
	unsigned int				_id;

public:
	op_kill(shared_connection c, thread_pool* tp);
	virtual ~op_kill();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_KILL_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
