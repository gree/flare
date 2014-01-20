/**
 *	op_parser_binary_node.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef OP_PARSER_BINARY_NODE_H
#define OP_PARSER_BINARY_NODE_H

#include "op_parser_binary.h"

namespace gree {
namespace flare {

/**
 *	opcode binary parser for node application
 */
class op_parser_binary_node : public op_parser_binary {
protected:
	virtual op* _determine_op(const binary_request_header&);

public:
	op_parser_binary_node(shared_connection c);
	virtual ~op_parser_binary_node();
};

}	// namespace flare
}	// namespace gree

#endif // OP_PARSER_BINARY_NODE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
