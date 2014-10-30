/**
 *	op_parser_text.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_PARSER_TEXT_H
#define	OP_PARSER_TEXT_H

#include "op_parser.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode text parser class
 */
class op_parser_text : public op_parser {
public:
	op_parser_text(shared_connection c);
	virtual ~op_parser_text();

	virtual op* parse_server();

protected:
	virtual op* _determine_op(const char* first, const char* buf, int& consume) = 0;
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PARSER_TEXT_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
