/**
 *	op_meta.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_META_H__
#define	__OP_META_H__

#include "op.h"
#include "cluster.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (meta)
 */
class op_meta : public op {
protected:
	cluster*	_cluster;

public:
	op_meta(shared_connection c, cluster* cl);
	virtual ~op_meta();

	virtual int run_client(int& partition_size, key_resolver::type& key_resolver_type, int& key_resolver_modular_hint, int& key_resolver_modular_virtual);

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client();
	virtual int _parse_client_parameter(int& partition_size, key_resolver::type& key_resolver_type, int& key_resolver_modular_hint, int& key_resolver_modular_virtual);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_META_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
