/**
 *	test_op_dump.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_dump.h>

using namespace gree::flare;

namespace test_op_dump
{
	TEST_OP_CLASS_BEGIN(op_dump, NULL, NULL)
		EXPOSE(op_dump, _wait);
		EXPOSE(op_dump, _partition);
		EXPOSE(op_dump, _partition_size);
		EXPOSE(op_dump, _bwlimit);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_dump op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(0, op._wait);
		cut_assert_equal_int(-1, op._partition);
		cut_assert_equal_int(0, op._partition_size);
		cut_assert_equal_int(0, op._bwlimit);
	}

	void test_parse_text_server_parameters_wait()
	{
		shared_connection c(new connection_sstream(" 1\r\n"));
		test_op_dump op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(1, op._wait);
		cut_assert_equal_int(-1, op._partition);
		cut_assert_equal_int(0, op._partition_size);
		cut_assert_equal_int(0, op._bwlimit);
	}

	void test_parse_text_server_parameters_wait_partition()
	{
		// partition but no valid partition_size
		shared_connection c(new connection_sstream(" 1 2\r\n"));
		test_op_dump op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_wait_partition_size()
	{
		{
			// partition == -1 -> partition_size == 0
			shared_connection c(new connection_sstream(" 1 -1 0\r\n"));
			test_op_dump op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(1, op._wait);
			cut_assert_equal_int(-1, op._partition);
			cut_assert_equal_int(0, op._partition_size);
			cut_assert_equal_int(0, op._bwlimit);
		}
		{
			// partition > 0 -> partition_size > partition + 1
			shared_connection c(new connection_sstream(" 1 2 5\r\n"));
			test_op_dump op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(1, op._wait);
			cut_assert_equal_int(2, op._partition);
			cut_assert_equal_int(5, op._partition_size);
			cut_assert_equal_int(0, op._bwlimit);
		}
	}

	void test_parse_text_server_parameters_wait_partition_size_fail()
	{
		{
			// Invalid number
			shared_connection c(new connection_sstream(" 1 2 invalid_size\r\n"));
			test_op_dump op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
		{
			// partition_size < partition + 1
			shared_connection c(new connection_sstream(" 1 2 1\r\n"));
			test_op_dump op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
	}

	void test_parse_text_server_parameters_wait_partition_size_bwlimit()
	{
		// partition == -1 -> partition_size == 0
		shared_connection c(new connection_sstream(" 1 -1 0 5\r\n"));
		test_op_dump op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(1, op._wait);
		cut_assert_equal_int(-1, op._partition);
		cut_assert_equal_int(0, op._partition_size);
		cut_assert_equal_int(5, op._bwlimit);
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
