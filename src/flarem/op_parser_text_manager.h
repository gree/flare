/**
 *	op_parser_text_manager.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __OP_PARSER_TEXT_MANAGER_H__
#define __OP_PARSER_TEXT_MANAGER_H__

#include "op_parser_text.h"
#include "op_stats_manager.h"

namespace gree {
namespace flare {

/**
 *	opcode text parser for manager application
 */
class op_parser_text_manager : public op_parser_text {
protected:

public:
	op_parser_text_manager(shared_connection c);
	virtual ~op_parser_text_manager();

protected:
	virtual op* _determine_op(const char* first, const char* buf);
};

}	// namespace flare
}	// namespace gree

#endif // __OP_PARSER_TEXT_MANAGER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
