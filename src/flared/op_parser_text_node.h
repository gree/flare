/**
 *	op_parser_text_node.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef OP_PARSER_TEXT_NODE_H
#define OP_PARSER_TEXT_NODE_H

#include "op_parser_text.h"

namespace gree {
namespace flare {

/**
 *	opcode text parser for node application
 */
class op_parser_text_node : public op_parser_text {
protected:

public:
	op_parser_text_node(shared_connection c);
	virtual ~op_parser_text_node();

protected:
	virtual op* _determine_op(const char* first, const char* buf, int& consume);
};

}	// namespace flare
}	// namespace gree

#endif // OP_PARSER_TEXT_NODE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
