/**
 *	op_delete.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_DELETE_H__
#define	__OP_DELETE_H__

#include "op_proxy_write.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (delete)
 */
class op_delete : public op_proxy_write {
public:
	op_delete(shared_connection c, cluster* cl, storage* st);
	virtual ~op_delete();

protected:
	op_delete(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	virtual int _parse_text_server_parameters();
	virtual int _parse_binary_request(const binary_request_header&, const char* body);
	virtual int _run_server();
	virtual int _run_client(storage::entry& e);
	virtual int _parse_text_client_parameters(storage::entry& e);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_DELETE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
