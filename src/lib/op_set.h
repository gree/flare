/**
 *	op_set.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_SET_H__
#define	__OP_SET_H__

#include "op.h"
#include "cluster.h"
#include "storage.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (set)
 */
class op_set : public op {
protected:
	cluster*					_cluster;
	storage*					_storage;
	storage::entry		_entry;

public:
	op_set(shared_connection c, cluster* cl, storage* st);
	virtual ~op_set();

	virtual int run_client();

	virtual storage::entry get_entry() { return this->_entry; };

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client();
	virtual int _parse_client_parameter();
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_SET_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
