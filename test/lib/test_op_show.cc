/**
 *	test_op_show.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_show.h>

using namespace gree::flare;

namespace test_op_show
{
	TEST_OP_CLASS_BEGIN(op_show)
		EXPOSE(op_show, _show_type);
		EXPOSE(op_show, show_type_error);
		EXPOSE(op_show, show_type_variables);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_show op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
		cut_assert_equal_int(test_op_show::show_type_error, op._show_type);
	}

	void test_parse_text_server_parameters_variables()
	{
		shared_connection c(new connection_sstream(" variables\r\n"));
		test_op_show op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(test_op_show::show_type_variables, op._show_type);
	}

	void test_parse_text_server_parameters_error()
	{
		shared_connection c(new connection_sstream(" anything\r\n"));
		test_op_show op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
		cut_assert_equal_int(test_op_show::show_type_error, op._show_type);
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
