/**
 *	test_op_ping.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_ping.h>

using namespace gree::flare;

namespace test_op_ping
{
	TEST_OP_CLASS_BEGIN(op_ping)
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_ping op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_garbage()
	{
		shared_connection c(new connection_sstream(" garbage\r\n"));
		test_op_ping op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
