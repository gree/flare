/**
 *	op_parser_binary_index.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef OP_PARSER_BINARY_INDEX_H
#define OP_PARSER_BINARY_INDEX_H

#include "op_parser_binary.h"

namespace gree {
namespace flare {

/**
 *	opcode binary parser for index application
 */
class op_parser_binary_index : public op_parser_binary {
protected:
	virtual op* _determine_op(const binary_request_header&) { return NULL; }

public:
	op_parser_binary_index(shared_connection c);
	virtual ~op_parser_binary_index();
};

}	// namespace flare
}	// namespace gree

#endif // OP_PARSER_BINARY_INDEX_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
