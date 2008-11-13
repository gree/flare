/**
 *	op_get.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_GET_H__
#define	__OP_GET_H__

#include "op_proxy_read.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (get)
 */
class op_get : public op_proxy_read {
protected:
	bool				_append_version;

public:
	op_get(shared_connection c, cluster* cl, storage* st);
	op_get(shared_connection c, string ident, cluster* cl, storage* st);
	virtual ~op_get();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client(storage::entry& e);
	virtual int _run_client(list<storage::entry>& e);
	virtual int _parse_client_parameter(storage::entry& e);
	virtual int _parse_client_parameter(list<storage::entry>& e);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_GET_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
