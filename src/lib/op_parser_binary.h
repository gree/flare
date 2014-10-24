/**
 *	op_parser_binary.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_PARSER_BINARY_H
#define	OP_PARSER_BINARY_H

#include "op_parser.h"
#include "binary_request_header.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode binary parser class
 */
class op_parser_binary : public op_parser {
public:
	op_parser_binary(shared_connection c);
	virtual ~op_parser_binary();

	virtual op* parse_server();

protected:
	virtual op* _determine_op(const binary_request_header&) = 0;
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PARSER_BINARY_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
