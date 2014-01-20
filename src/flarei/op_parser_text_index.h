/**
 *	op_parser_text_index.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef OP_PARSER_TEXT_INDEX_H
#define OP_PARSER_TEXT_INDEX_H

#include "op_parser_text.h"
#include "op_stats_index.h"
#include "op_show_index.h"
#include "op_shutdown.h"

namespace gree {
namespace flare {

/**
 *	opcode text parser for index application
 */
class op_parser_text_index : public op_parser_text {
protected:

public:
	op_parser_text_index(shared_connection c);
	virtual ~op_parser_text_index();

protected:
	virtual op* _determine_op(const char* first, const char* buf, int& consume);
};

}	// namespace flare
}	// namespace gree

#endif // OP_PARSER_TEXT_INDEX_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
