/**
 *	op_meta.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_META_H
#define	OP_META_H

#include "op.h"
#include "cluster.h"

using namespace std;

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

	virtual int run_client(int& partition_size, storage::hash_algorithm& key_hash_algorithm, key_resolver::type& key_resolver_type, int& key_resolver_modular_hint, int& key_resolver_modular_virtual);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client();
	virtual int _parse_text_client_parameters(int& partition_size, storage::hash_algorithm& key_hash_algorithm, key_resolver::type& key_resolver_type, int& key_resolver_modular_hint, int& key_resolver_modular_virtual);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_META_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
