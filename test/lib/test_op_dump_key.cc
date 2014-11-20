/**
 *	test_op_dump_key.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>
#include <iomanip>

#include "test_op.h"
#include "connection_iostream.h"
#include "mock_storage.h"

#include <app.h>
#include <op_dump_key.h>

using namespace gree::flare;

namespace test_op_dump_key
{
	TEST_OP_CLASS_BEGIN(op_dump_key, NULL, NULL)
		test_op_dump_key(shared_connection c, cluster* cl, storage* st) : op_dump_key(c, cl, st) { };
		EXPOSE(op_dump_key, _partition);
		EXPOSE(op_dump_key, _partition_size);
		EXPOSE(op_dump_key, _bwlimitter);
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
		cut_assert_equal_int(0, op._bwlimitter.get_bwlimit());
	}

	void test_parse_text_server_parameters_partition()
	{
		// partition but no valid partition_size
		shared_connection c(new connection_sstream(" 2\r\n"));
		test_op_dump_key op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
		cut_assert_equal_int(0, op._bwlimitter.get_bwlimit());
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
			cut_assert_equal_int(0, op._bwlimitter.get_bwlimit());
		}
		{
			// partition > 0 -> partition_size > partition + 1
			shared_connection c(new connection_sstream(" 2 5\r\n"));
			test_op_dump_key op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(2, op._partition);
			cut_assert_equal_int(5, op._partition_size);
			cut_assert_equal_int(0, op._bwlimitter.get_bwlimit());
		}
	}

	void test_parse_text_server_parameters_bwlimit()
	{
		shared_connection c(new connection_sstream(" 2 5 1000\r\n"));
		test_op_dump_key op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(2, op._partition);
		cut_assert_equal_int(5, op._partition_size);
		cut_assert_equal_int(1000, op._bwlimitter.get_bwlimit());
	}

	void set_dummy_items(mock_storage& st, int item_num = 1, int item_key_size = 1)
	{
		for (int i = 0; i < item_num; i++) {
			ostringstream key;
			key << setfill('k') << std::setw(item_key_size) << i;
			st.set_helper(key.str(), string("o"), 0);
		}
	}

	void run_server_test(test_op_dump_key& op, int item_num, int item_key_size, int bwlimit = 0, int sleep_precision = 1)
	{
		static const long one_sec = 1000000L;
		static const long delta   =  100000L;
		struct timeval start_tv, end_tv;

		gettimeofday(&start_tv, NULL);
		op._run_server();
		gettimeofday(&end_tv, NULL);

		if (bwlimit == 0) {
			return;
		}

		long elapsed_usec = ((end_tv.tv_sec - start_tv.tv_sec) * one_sec + (end_tv.tv_usec - start_tv.tv_usec));
		long estimated_bwlimit_usec = 0;
		if (bwlimit != 0) {
			estimated_bwlimit_usec = item_num * (item_key_size + 8) * one_sec / (bwlimit * 1024);
		}

		long actual_sleep = elapsed_usec / sleep_precision;
		long expected_sleep = estimated_bwlimit_usec / sleep_precision;
		cut_assert(abs(actual_sleep - expected_sleep) < delta);
	}

	void test_run_server()
	{
		static const long one_sec = 1000000L;
		int bwlimit = 1000; // KB
		int item_key_size = 1024;
		int item_num = bwlimit * 1024 / (item_key_size + 8);

		shared_connection c(new connection_sstream(" -1 0 1000\r\n"));
		cluster cl(NULL, "", 0);
		mock_storage st("", 0, 0);
		thread_pool tp(1);
		test_op_dump_key op(c, &cl, &st);
		op.set_thread(shared_thread(new gree::flare::thread(&tp)));
		set_dummy_items(st, item_num, item_key_size);
		cut_assert_equal_int(item_num, st.count());
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(bwlimit, op._bwlimitter.get_bwlimit());
		run_server_test(op, item_num, item_key_size, bwlimit, 1);
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
