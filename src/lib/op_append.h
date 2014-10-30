/**
 *	op_append.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_APPEND_H
#define	OP_APPEND_H

#include "op_set.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (append)
 */
class op_append : public op_set {
public:
	op_append(shared_connection c, cluster* cl, storage* st);
	virtual ~op_append();

protected:
	op_append(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	virtual int _parse_binary_request(const binary_request_header&, const char* body);

private:
	static const uint8_t _binary_request_required_extras_length = 0;
};

}	// namespace flare
}	// namespace gree

#endif	// OP_APPEND_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
