/**
 *	test_op_error.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_error.h>

using namespace gree::flare;

namespace test_op_error
{
	TEST_OP_CLASS_BEGIN(op_error)
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_error op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_anything()
	{
		// Check that it consumes the whole line
		shared_connection c(new connection_sstream(" line 1\r\nline2\r\n"));
		test_op_error op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		char* line2;
		c->readline(&line2);
		cut_assert_equal_string("line2\n", line2);
		delete[] line2;
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
