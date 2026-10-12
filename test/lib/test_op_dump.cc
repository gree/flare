/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
/**
 *	test_op_dump.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"
#include "mock_storage.h"

#include <app.h>
#include <op_dump.h>
#include <connection_tcp.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <pthread.h>
#include <time.h>

using namespace gree::flare;

namespace test_op_dump
{
	TEST_OP_CLASS_BEGIN(op_dump, NULL, NULL)
		test_op_dump(shared_connection c, cluster* cl, storage* st) : op_dump(c, cl, st) { };
		EXPOSE(op_dump, _wait);
		EXPOSE(op_dump, _partition);
		EXPOSE(op_dump, _partition_size);
		EXPOSE(op_dump, _bwlimitter);
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
		cut_assert_equal_int(0, op._bwlimitter.get_bwlimit());
	}

	void test_parse_text_server_parameters_wait()
	{
		shared_connection c(new connection_sstream(" 1\r\n"));
		test_op_dump op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(1, op._wait);
		cut_assert_equal_int(-1, op._partition);
		cut_assert_equal_int(0, op._partition_size);
		cut_assert_equal_int(0, op._bwlimitter.get_bwlimit());
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
			cut_assert_equal_int(0, op._bwlimitter.get_bwlimit());
		}
		{
			// partition > 0 -> partition_size > partition + 1
			shared_connection c(new connection_sstream(" 1 2 5\r\n"));
			test_op_dump op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(1, op._wait);
			cut_assert_equal_int(2, op._partition);
			cut_assert_equal_int(5, op._partition_size);
			cut_assert_equal_int(0, op._bwlimitter.get_bwlimit());
		}
	}

	// Regression: partition >= partition_size (incl. partition 0 with size 0,
	// which dereferenced the resolver's NULL row 0) must be rejected at parse
	// time, before run_server can reach the key resolver.
	void test_parse_text_server_parameters_partition_out_of_range()
	{
		{
			shared_connection c(new connection_sstream(" 0 0 0\r\n"));
			test_op_dump op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
		{
			shared_connection c(new connection_sstream(" 1 2 2\r\n"));
			test_op_dump op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
		{
			shared_connection c(new connection_sstream(" 1 5 2\r\n"));
			test_op_dump op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
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
		cut_assert_equal_int(5, op._bwlimitter.get_bwlimit());
	}

	void set_dummy_items(mock_storage& st, int item_num = 1, int item_size = 1)
	{
		for (int i = 0; i < item_num; i++) {
			string key = string("key") + boost::lexical_cast<string>(i);
			ostringstream value;
			for (int j = 0; j < item_size; j++) {
				value << "o";
			}
			st.set_helper(key, value.str(), 0);
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
		                   int sleep_precision = 1)
	{
		static const long one_sec = 1000000L;
		struct timeval start_tv, end_tv;

		gettimeofday(&start_tv, NULL);
		op._run_server();
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

		// Wall-clock quantized by sleep_precision: scheduling jitter on a
		// loaded machine routinely lands the elapsed time in the NEXT
		// bucket (expected 10, actual 11 — a recurring flake). The op must
		// sleep at least the throttle budget; allow one bucket of overshoot.
		if (actual_sleep < expected_sleep || actual_sleep > expected_sleep + 1) {
			cut_assert_equal_int(expected_sleep, actual_sleep);
		}
	}

	void test_run_server()
	{
		shared_connection c(new connection_sstream("\r\n"));
		connection_sstream& cstr = dynamic_cast<connection_sstream&>(*c);
		cluster cl(NULL, NULL, "", 0);
		mock_storage st("", 0, 0);
		AtomicCounter thread_idx(1);
		thread_pool tp(1, 128, &thread_idx);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new gree::flare::thread(&tp)));

		set_dummy_items(st, 5, 5);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		run_server_test(op, 5, 5);
		run_server_output_test(cstr.get_output(), 5, 5);
	}

	void test_run_server_wait()
	{
		shared_connection c(new connection_sstream(" 1000000\r\n"));
		cluster cl(NULL, NULL, "", 0);
		mock_storage st("", 0, 0);
		AtomicCounter thread_idx(1);
		thread_pool tp(1, 128, &thread_idx);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new gree::flare::thread(&tp)));

		set_dummy_items(st, 1, 10);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(1000000, op._wait);
		cut_assert_equal_int(0, op._bwlimitter.get_bwlimit());
		run_server_test(op, 1, 10, 1000000, 0, 100000);
	}

	void test_run_server_bwlimit()
	{
		shared_connection c(new connection_sstream(" 0 -1 0 1\r\n"));
		cluster cl(NULL, NULL, "", 0);
		mock_storage st("", 0, 0);
		AtomicCounter thread_idx(1);
		thread_pool tp(1, 128, &thread_idx);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new gree::flare::thread(&tp)));

		set_dummy_items(st, 1, 1024);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(0, op._wait);
		cut_assert_equal_int(1, op._bwlimitter.get_bwlimit());
		run_server_test(op, 1, 1024, 0, 1, 100000);
	}

	void test_run_server_wait_over_bwlimit()
	{
		shared_connection c(new connection_sstream(" 2000000 -1 0 1\r\n"));
		cluster cl(NULL, NULL, "", 0);
		mock_storage st("", 0, 0);
		AtomicCounter thread_idx(1);
		thread_pool tp(1, 128, &thread_idx);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new gree::flare::thread(&tp)));

		set_dummy_items(st, 1, 1024);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(2000000, op._wait);
		cut_assert_equal_int(1, op._bwlimitter.get_bwlimit());
		run_server_test(op, 1, 1024, 2000000, 1, 100000);
	}

	void test_run_server_bwlimit_over_wait()
	{
		shared_connection c(new connection_sstream(" 100 -1 0 1\r\n"));
		cluster cl(NULL, NULL, "", 0);
		mock_storage st("", 0, 0);
		AtomicCounter thread_idx(1);
		thread_pool tp(1, 128, &thread_idx);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new gree::flare::thread(&tp)));

		set_dummy_items(st, 1, 1024);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(100, op._wait);
		cut_assert_equal_int(1, op._bwlimitter.get_bwlimit());
		run_server_test(op, 1, 1024, 100, 1, 100000);
	}


	// ---- serve bound (review 2026-10-12, round 8): a dump receiver that
	// stays connected but stops reading held the source's iterator (on
	// RocksDB a snapshot pinning files and memtables; "database busy" for
	// every other dump) for as long as it stayed connected.
	namespace {
		uint64_t dump_mono_ms() {
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
		}

		struct dump_serve_run {
			test_op_dump* op;
			volatile bool done;
			int result;
			static void* run(void* a) {
				dump_serve_run* self = static_cast<dump_serve_run*>(a);
				self->result = self->op->_run_server();
				self->done = true;
				return NULL;
			}
		};
	}

	// Old code: the serve blocks in write() until the peer goes away — here
	// until this test's 10 s guard closes the peer ("did not end").
	void test_run_server_ends_when_the_receiver_stops_reading()
	{
		int lfd = socket(AF_INET, SOCK_STREAM, 0);
		struct sockaddr_in addr;
		memset(&addr, 0, sizeof(addr));
		addr.sin_family = AF_INET;
		addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		bind(lfd, (struct sockaddr*)&addr, sizeof(addr));
		listen(lfd, 1);
		socklen_t l = sizeof(addr);
		getsockname(lfd, (struct sockaddr*)&addr, &l);
		int cfd = socket(AF_INET, SOCK_STREAM, 0);
		int small = 4096;
		setsockopt(cfd, SOL_SOCKET, SO_RCVBUF, &small, sizeof(small));
		cut_assert_equal_int(0, connect(cfd, (struct sockaddr*)&addr, sizeof(addr)));
		struct sockaddr_in peer;
		socklen_t pl = sizeof(peer);
		int afd = accept(lfd, (struct sockaddr*)&peer, &pl);
		cut_assert_operator(afd, >=, 0);
		int sb = 16384;
		setsockopt(afd, SOL_SOCKET, SO_SNDBUF, &sb, sizeof(sb));
		fcntl(afd, F_SETFL, fcntl(afd, F_GETFL, 0) | O_NONBLOCK);

		const int saved = op_dump::serve_progress_timeout_ms;
		op_dump::serve_progress_timeout_ms = 1500;
		connection_tcp* t = new connection_tcp(afd, addr);
		shared_connection c(t);
		cluster cl(NULL, NULL, "", 0);
		mock_storage st("", 0, 0);
		AtomicCounter thread_idx(1);
		thread_pool tp(1, 128, &thread_idx);
		test_op_dump op(c, &cl, &st);
		op.set_thread(shared_thread(new gree::flare::thread(&tp)));
		set_dummy_items(st, 2000, 8192);		// ~16 MB: far beyond both buffers

		dump_serve_run sr;
		sr.op = &op;
		sr.done = false;
		sr.result = 0;
		pthread_t th;
		const uint64_t t0 = dump_mono_ms();
		cut_assert_equal_int(0, pthread_create(&th, NULL, &dump_serve_run::run, &sr));
		while (!sr.done && dump_mono_ms() - t0 < 10000) {
			usleep(50 * 1000);
		}
		const bool ended_by_itself = sr.done;
		const uint64_t took = dump_mono_ms() - t0;
		::close(cfd);		// the guard: unblocks a serve that did not end
		pthread_join(th, NULL);
		::close(lfd);
		op_dump::serve_progress_timeout_ms = saved;
		cut_notify("dump serve to a stalled receiver: ended by itself=%d after %llu ms, result %d, errno %d",
			(int)ended_by_itself, (unsigned long long)took, sr.result, t->get_errno());
		cut_assert_true(ended_by_itself, cut_message("the dump serve did not end within 10 s of a receiver that stopped reading"));
		cut_assert_operator(took, <, (uint64_t)8000);
		cut_assert_equal_int(-4, t->get_errno());
		// the iterator is released: the next dump is not "database busy"
		cut_assert_equal_int(0, st.iter_begin());
		st.iter_end();
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
