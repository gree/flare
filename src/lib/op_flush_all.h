/**
 *	op_flush_all.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_FLUSH_ALL_H__
#define	__OP_FLUSH_ALL_H__

#include "op.h"
#include "storage.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (flush_all)
 */
class op_flush_all : public op {
protected:
	storage*					_storage;
	int								_expire;
	int								_option;

public:
	op_flush_all(shared_connection c, storage* st);
	virtual ~op_flush_all();

	virtual int run_client(time_t expire, storage::option option);

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client(time_t expire, storage::option option);
	virtual int _parse_client_parameter(storage::option option);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_FLUSH_ALL_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
