/**
 *	test_write_fence.cc
 *
 *	The planned-eviction write fence (src/lib/write_fence.h,
 *	docs/design-node-operations-2026-10-19.md): arm / re-arm / release / TTL,
 *	the in-flight count the barrier relies on, and the refusal of every gated
 *	mutation op while armed (before it touches the cluster or the storage).
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <write_fence.h>
#include <op_set.h>
#include <op_delete.h>
#include <op_incr.h>
#include <op_flush_all.h>
#include <op_fence.h>

using namespace gree::flare;

namespace test_write_fence
{
	static time_t fake_now = 1000;
	static time_t fake_clock() { return fake_now; }

	TEST_OP_CLASS_BEGIN(op_set, NULL, NULL)
		EXPOSE(op_set, _entry);
	TEST_OP_CLASS_END;
	TEST_OP_CLASS_BEGIN(op_delete, NULL, NULL)
	TEST_OP_CLASS_END;
	TEST_OP_CLASS_BEGIN(op_incr, NULL, NULL)
	TEST_OP_CLASS_END;
	TEST_OP_CLASS_BEGIN(op_flush_all, NULL)
	TEST_OP_CLASS_END;
	TEST_OP_CLASS_BEGIN(op_fence)
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		write_fence::reset_for_test();
		fake_now = 1000;
		write_fence::set_clock(fake_clock);
	}

	void teardown()
	{
		write_fence::reset_for_test();
	}

	void test_arm_release_and_token()
	{
		std::string why;
		cut_assert_false(write_fence::active());
		cut_assert_true(write_fence::arm("t1", 30, why));
		cut_assert_true(write_fence::active());
		cut_assert_equal_string("t1", write_fence::token().c_str());
		cut_assert_equal_int(30, write_fence::remaining_sec());
		// another token cannot take or release it
		cut_assert_false(write_fence::arm("t2", 30, why));
		cut_assert_equal_string("fenced by another token", why.c_str());
		cut_assert_false(write_fence::release("t2"));
		cut_assert_true(write_fence::active());
		// the holder releases it; releasing again is a no-op
		cut_assert_true(write_fence::release("t1"));
		cut_assert_false(write_fence::active());
		cut_assert_true(write_fence::release("t1"));
	}

	void test_rearm_extends_and_ttl_releases()
	{
		std::string why;
		cut_assert_true(write_fence::arm("t1", 10, why));
		fake_now += 8;
		cut_assert_true(write_fence::arm("t1", 10, why));		// re-armed by its holder
		fake_now += 8;
		cut_assert_true(write_fence::active());					// 16 s after the first arm
		fake_now += 3;
		cut_assert_false(write_fence::active());				// not re-armed: released by itself
		cut_assert_equal_string("", write_fence::token().c_str());
		cut_assert_true(write_fence::arm("t2", 10, why));		// another token may arm now
	}

	void test_invalid_arguments()
	{
		std::string why;
		cut_assert_false(write_fence::arm("", 10, why));
		cut_assert_false(write_fence::arm("a b", 10, why));
		cut_assert_false(write_fence::arm("t", 0, why));
		cut_assert_false(write_fence::arm("t", 3601, why));
		cut_assert_false(write_fence::active());
	}

	void test_in_flight_and_refused()
	{
		std::string why;
		{
			write_fence::entry a;
			write_fence::entry b;
			cut_assert_false(a.fenced());
			cut_assert_equal_int(2, write_fence::in_flight());
			// armed while two mutations are in flight: they stay counted
			cut_assert_true(write_fence::arm("t1", 30, why));
			cut_assert_equal_int(2, write_fence::in_flight());
			// a NEW mutation is refused and not counted
			write_fence::entry c;
			cut_assert_true(c.fenced());
			cut_assert_equal_int(2, write_fence::in_flight());
			cut_assert_equal_int(1, write_fence::refused());
		}
		// both finished: the barrier may be read now
		cut_assert_equal_int(0, write_fence::in_flight());
	}

	void test_set_refused_while_fenced()
	{
		std::string why;
		cut_assert_true(write_fence::arm("t1", 30, why));
		// NULL cluster and storage: a refused op must return before using them
		shared_connection c(new connection_sstream(" key 0 0 5\r\nVALUE\r\n"));
		test_op_set op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		op._run_server();
		cut_assert_equal_string("SERVER_ERROR fenced\r\n", dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		cut_assert_equal_int(0, write_fence::in_flight());
	}

	void test_set_noreply_refused_silently()
	{
		std::string why;
		cut_assert_true(write_fence::arm("t1", 30, why));
		shared_connection c(new connection_sstream(" key 0 0 5 noreply\r\nVALUE\r\n"));
		test_op_set op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(0, op._run_server());
		cut_assert_equal_string("", dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		cut_assert_equal_int(1, write_fence::refused());
	}

	void test_delete_incr_flush_all_refused_while_fenced()
	{
		std::string why;
		cut_assert_true(write_fence::arm("t1", 30, why));
		{
			shared_connection c(new connection_sstream(" key\r\n"));
			test_op_delete op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			op._run_server();
			cut_assert_equal_string("SERVER_ERROR fenced\r\n", dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		}
		{
			shared_connection c(new connection_sstream(" key 1\r\n"));
			test_op_incr op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			op._run_server();
			cut_assert_equal_string("SERVER_ERROR fenced\r\n", dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		}
		{
			// the same empty input test_op_flush_all parses
			shared_connection c(new connection_sstream(std::string()));
			test_op_flush_all op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			op._run_server();
			cut_assert_equal_string("SERVER_ERROR fenced\r\n", dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		}
		cut_assert_equal_int(3, write_fence::refused());
	}

	void test_op_fence_arm_status_release()
	{
		{
			shared_connection c(new connection_sstream(" arm tok 20\r\n"));
			test_op_fence op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			op._run_server();
			cut_assert_equal_string("STAT fence_active 1\r\nSTAT fence_token tok\r\nSTAT fence_remaining_sec 20\r\nSTAT fence_in_flight 0\r\nEND\r\n",
				dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		}
		{
			shared_connection c(new connection_sstream(" arm other 20\r\n"));
			test_op_fence op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			op._run_server();
			cut_assert_equal_string("SERVER_ERROR fenced by another token\r\n", dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		}
		{
			shared_connection c(new connection_sstream(" release tok\r\n"));
			test_op_fence op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			op._run_server();
			cut_assert_equal_string("STAT fence_active 0\r\nSTAT fence_token -\r\nSTAT fence_remaining_sec 0\r\nSTAT fence_in_flight 0\r\nEND\r\n",
				dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		}
		{
			shared_connection c(new connection_sstream(" bogus\r\n"));
			test_op_fence op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
