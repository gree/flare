/**
 *	op_keys.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_KEYS_H
#define	OP_KEYS_H

#include "op_proxy_read.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (keys)
 */
class op_keys : public op_proxy_read {
protected:

public:
	op_keys(shared_connection c, cluster* cl, storage* st);
	virtual ~op_keys();

protected:
	int _parse_text_server_parameters();
	int _run_server();
	int _run_client(storage::entry&e, void* parameter);
	int _run_client(list<storage::entry>& e, void* parameter);
	int _parse_text_client_parameters(storage::entry& e);
	int _parse_text_client_parameters(list<storage::entry>& e);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_KEYS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
