/**
 *	test_op_parser.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <op_parser_binary.h>
#include <op_parser_text.h>

using namespace gree::flare;

namespace test_op_parser
{

class op_parser_binary_test : public op_parser_binary
{
public:
	op_parser_binary_test(shared_connection c)
		: op_parser_binary(c) { }
	virtual ~op_parser_binary_test() { }

protected:
	op* _determine_op(const binary_request_header&) { return NULL; }
};

class op_parser_text_test : public op_parser_text
{
public:
	op_parser_text_test(shared_connection c)
		: op_parser_text(c) { }
	virtual ~op_parser_text_test() { }

protected:
	op* _determine_op(const char* first, const char* buf, int& consume);
};

}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
