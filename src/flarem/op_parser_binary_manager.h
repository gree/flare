/**
 *	op_parser_binary_manager.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __OP_PARSER_BINARY_MANAGER_H__
#define __OP_PARSER_BINARY_MANAGER_H__

#include "op_parser_binary.h"

namespace gree {
namespace flare {

/**
 *	opcode binary parser for manager application
 */
class op_parser_binary_manager : public op_parser_binary {
protected:

public:
	op_parser_binary_manager(shared_connection c);
	virtual ~op_parser_binary_manager();
};

}	// namespace flare
}	// namespace gree

#endif // __OP_PARSER_BINARY_MANAGER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
