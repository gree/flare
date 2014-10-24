/**
 *	op_get.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_GET_H
#define	OP_GET_H

#include "op_proxy_read.h"

using namespace std;

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
	virtual ~op_get();

protected:
	op_get(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	virtual int _parse_text_server_parameters();
	virtual int _parse_binary_request(const binary_request_header&, const char* body);
	virtual int _run_server();
	virtual int _run_client(storage::entry& e, void* parameter);
	virtual int _run_client(list<storage::entry>& e, void* parameter);
	virtual int _parse_text_client_parameters(storage::entry& e);
	virtual int _parse_text_client_parameters(list<storage::entry>& e);
	virtual int _send_binary_result(result r, const char* message = NULL);

private:
	inline int _send_entry(const storage::entry&);
	int _send_text_entry(const storage::entry&);
	int _send_binary_entry(const storage::entry&);

	static const uint8_t _binary_request_required_extras_length = 0;
};

int op_get::_send_entry(const storage::entry& entry) {
	return _protocol == op::text
		? _send_text_entry(entry)
		: _send_binary_entry(entry);
}

}	// namespace flare
}	// namespace gree

#endif	// OP_GET_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
