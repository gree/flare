/**
 *	test_op_dump.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"
#include "storage_simple_map.h"

#include <app.h>
#include <op_dump.h>

using namespace gree::flare;

namespace test_op_dump
{
	TEST_OP_CLASS_BEGIN(op_dump, NULL, NULL)
		test_op_dump(shared_connection c, cluster* cl, storage* st) : op_dump(c, cl, st) { };
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

	void set_dummy_items(storage_simple_map& st, int item_num = 1, int item_size = 1)
	{
		for (int i = 0; i < item_num; i++) {
			string key = string("key") + boost::lexical_cast<string>(i);
			ostringstream value;
			for (int j = 0; j < item_size; j++) {
				value << "o";
			}
			st.set(key, value.str(), 0);
		}
	}

	void run_server_output_test(const string& output, int item_num = 1, int item_size = 1)
	{
		ostringstream expected;
		for (int i = 0; i < item_num; i++) {
			expected << "VALUE key" << i << " 0 " << item_size << " 0 0\r\n";
			for (int j = 0; j < item_size; j++) {
				expected << "o";
			}
			expected << "\r\n";
		}
		expected << "END\r\n";
		cut_assert_equal_string(expected.str().c_str(), output.c_str());
	}

	void run_server_test(test_op_dump& op, int item_num, int item_size, int wait = 0, int bwlimit = 0,
		                   int sleep_precision = 1, int expected = 0)
	{
		static const long one_sec = 1000000L;
		struct timeval start_tv, end_tv;

		gettimeofday(&start_tv, NULL);
		cut_assert_equal_int(expected, op._run_server());
		gettimeofday(&end_tv, NULL);

		if (wait == 0 && bwlimit == 0) {
			return;
		}

		long elapsed_usec = ((end_tv.tv_sec - start_tv.tv_sec) * one_sec + (end_tv.tv_usec - start_tv.tv_usec));
		long estimated_wait_usec = item_num * wait;
		long estimated_bwlimit_usec = 0;
		if (bwlimit != 0) {
			estimated_bwlimit_usec = item_num * item_size * one_sec / (bwlimit * 1024);
		}

		long actual_sleep = elapsed_usec / sleep_precision;
		long expected_sleep;
		if (estimated_wait_usec >= estimated_bwlimit_usec) {
			expected_sleep = estimated_wait_usec / sleep_precision;
		} else {
			expected_sleep = estimated_bwlimit_usec / sleep_precision;
		}

		cut_assert_equal_int(expected_sleep, actual_sleep);
	}

	void test_run_server()
	{
		shared_connection c(new connection_sstream("\r\n"));
		connection_sstream& cstr = dynamic_cast<connection_sstream&>(*c);
		cluster cl(NULL, "", 0);
		storage_simple_map st("", 0, 0);
		thread_pool tp(1);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new thread(&tp)));

		set_dummy_items(st, 5, 5);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		run_server_test(op, 5, 5);
		run_server_output_test(cstr.get_output(), 5, 5);
	}

	void test_run_server_wait()
	{
		shared_connection c(new connection_sstream(" 1000000\r\n"));
		cluster cl(NULL, "", 0);
		storage_simple_map st("", 0, 0);
		thread_pool tp(1);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new thread(&tp)));

		set_dummy_items(st, 1, 10);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(1000000, op._wait);
		cut_assert_equal_int(0, op._bwlimit);
		run_server_test(op, 1, 10, 1000000, 0, 100000);
	}

	void test_run_server_bwlimit()
	{
		shared_connection c(new connection_sstream(" 0 -1 0 1\r\n"));
		cluster cl(NULL, "", 0);
		storage_simple_map st("", 0, 0);
		thread_pool tp(1);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new thread(&tp)));

		set_dummy_items(st, 1, 1024);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(0, op._wait);
		cut_assert_equal_int(1, op._bwlimit);
		run_server_test(op, 1, 1024, 0, 1, 100000);
	}

	void test_run_server_wait_over_bwlimit()
	{
		shared_connection c(new connection_sstream(" 2000000 -1 0 1\r\n"));
		cluster cl(NULL, "", 0);
		storage_simple_map st("", 0, 0);
		thread_pool tp(1);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new thread(&tp)));

		set_dummy_items(st, 1, 1024);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(2000000, op._wait);
		cut_assert_equal_int(1, op._bwlimit);
		run_server_test(op, 1, 1024, 2000000, 1, 100000);
	}

	void test_run_server_bwlimit_over_wait()
	{
		shared_connection c(new connection_sstream(" 100 -1 0 1\r\n"));
		cluster cl(NULL, "", 0);
		storage_simple_map st("", 0, 0);
		thread_pool tp(1);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new thread(&tp)));

		set_dummy_items(st, 1, 1024);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(100, op._wait);
		cut_assert_equal_int(1, op._bwlimit);
		run_server_test(op, 1, 1024, 100, 1, 100000);
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
