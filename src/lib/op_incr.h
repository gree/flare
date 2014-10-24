/**
 *	op_incr.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_INCR_H
#define	OP_INCR_H

#include "op_proxy_write.h"

using namespace std;

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
	virtual ~op_incr();

	int set_value(uint64_t value) { this->_value = value; return 0; };
	uint64_t get_value() { return this->_value; };

protected:
	op_incr(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	virtual int _parse_text_server_parameters();
	virtual int _parse_binary_request(const binary_request_header&, const char* body);
	virtual int _run_server();
	virtual int _run_client(storage::entry& e);
	virtual int _parse_text_client_parameters(storage::entry& e);
	virtual int _send_text_result(result r, const char* message = NULL);
	virtual int _send_binary_result(result r, const char* message = NULL);

private:
	static const uint8_t _binary_request_required_extras_length = 20;
	static const uint32_t _binary_request_expire_magic = 0xffffffff;
};

}	// namespace flare
}	// namespace gree

#endif	// OP_INCR_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
