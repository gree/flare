/**
 *	test_op_kill.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_kill.h>

using namespace gree::flare;

namespace test_op_kill
{
	TEST_OP_CLASS_BEGIN(op_kill, NULL)
		EXPOSE(op_kill, _id);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_kill op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_id()
	{
		shared_connection c(new connection_sstream(" 1\r\n"));
		test_op_kill op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(1, op._id);
	}

	void test_parse_text_server_parameters_id_fail()
	{
		shared_connection c(new connection_sstream(" id\r\n"));
		test_op_kill op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_id_garbage()
	{
		shared_connection c(new connection_sstream(" 1 garbage\r\n"));
		test_op_kill op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
