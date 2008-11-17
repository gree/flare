/**
 *	op_set.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_SET_H__
#define	__OP_SET_H__

#include "op_proxy_write.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (set)
 */
class op_set : public op_proxy_write {
protected:
	int			_behavior;

public:
	op_set(shared_connection c, cluster* cl, storage* st);
	op_set(shared_connection c, string ident, cluster* cl, storage* st);
	virtual ~op_set();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client(storage::entry& e);
	virtual int _parse_client_parameter(storage::entry& e);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_SET_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
