/**
 *	op_parser_text.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_PARSER_TEXT_H__
#define	__OP_PARSER_TEXT_H__

#include "op_parser.h"

using namespace std;
using namespace boost;

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

#endif	// __OP_PARSER_TEXT_H_
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
