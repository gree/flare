/**
 *	test_op_dump_key.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_dump_key.h>

using namespace gree::flare;

namespace test_op_dump_key
{
	TEST_OP_CLASS_BEGIN(op_dump_key, NULL, NULL)
		EXPOSE(op_dump_key, _partition);
		EXPOSE(op_dump_key, _partition_size);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_dump_key op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(-1, op._partition);
		cut_assert_equal_int(0, op._partition_size);
	}

	void test_parse_text_server_parameters_partition()
	{
		// partition but no valid partition_size
		shared_connection c(new connection_sstream(" 2\r\n"));
		test_op_dump_key op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_partition_size()
	{
		{
			// partition == -1 -> partition_size == 0
			shared_connection c(new connection_sstream(" -1 0\r\n"));
			test_op_dump_key op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(-1, op._partition);
			cut_assert_equal_int(0, op._partition_size);
		}
		{
			// partition > 0 -> partition_size > partition + 1
			shared_connection c(new connection_sstream(" 2 5\r\n"));
			test_op_dump_key op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(2, op._partition);
			cut_assert_equal_int(5, op._partition_size);
		}
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
