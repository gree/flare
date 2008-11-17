/**
 *	op_incr.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_INCR_H__
#define	__OP_INCR_H__

#include "op_proxy_write.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (incr)
 */
class op_incr : public op_proxy_write {
protected:
	bool				_incr;
	uint64_t		_value;

public:
	op_incr(shared_connection c, cluster* cl, storage* st);
	op_incr(shared_connection c, string ident, cluster* cl, storage* st);
	virtual ~op_incr();

	int set_value(uint64_t value) { this->_value = value; return 0; };
	uint64_t get_value() { return this->_value; };

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client(storage::entry& e);
	virtual int _parse_client_parameter(storage::entry& e);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_INCR_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
