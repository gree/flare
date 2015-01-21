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
 *	test_op_stats.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_stats.h>
#include <binary_request_header.h>

#define _TEST_PARSE_TEXT_SERVER_PARAMETERS(statscmd, statsid) \
	void test_parse_text_server_parameters_##statsid() \
	{ \
		std::ostringstream os; \
		os << " " << #statscmd << "\r\n"; \
		shared_connection c(new connection_sstream(os.str())); \
		test_op_stats op(c); \
		cut_assert_equal_int(0, op._parse_text_server_parameters()); \
		cut_assert_equal_int(test_op_stats::stats_type_##statsid, op._stats_type); \
	}
#define TEST_PARSE_TEXT_SERVER_PARAMETERS(statscmd) _TEST_PARSE_TEXT_SERVER_PARAMETERS(statscmd, statscmd)
#define TEST_PARSE_TEXT_SERVER_PARAMETERS2(statscmd1, statscmd2) _TEST_PARSE_TEXT_SERVER_PARAMETERS(statscmd1 statscmd2, statscmd1##_##statscmd2)

#define _TEST_PARSE_BINARY_SERVER_PARAMETERS(statscmd, statsid) \
	void test_parse_binary_server_parameters_##statsid() \
	{ \
		std::string command = #statscmd; \
		binary_request_header header(binary_header::opcode_stat); \
		header.set_total_body_length(command.size()); \
		shared_connection c(new connection_sstream(header, command.data())); \
		test_op_stats op(c); \
		cut_assert_equal_int(0, op._parse_binary_server_parameters()); \
		cut_assert_equal_int(test_op_stats::stats_type_##statsid, op._stats_type); \
	}
#define TEST_PARSE_BINARY_SERVER_PARAMETERS(statscmd) _TEST_PARSE_BINARY_SERVER_PARAMETERS(statscmd, statscmd)
#define TEST_PARSE_BINARY_SERVER_PARAMETERS2(statscmd1, statscmd2) _TEST_PARSE_BINARY_SERVER_PARAMETERS(statscmd1 statscmd2, statscmd1##_##statscmd2)

using namespace gree::flare;

namespace test_op_stats
{
	TEST_OP_CLASS_BEGIN(op_stats)
		EXPOSE(op, _parse_binary_server_parameters);
		EXPOSE(op_stats, _stats_type);
		EXPOSE(op_stats, stats_type_error);
		EXPOSE(op_stats, stats_type_default);
		EXPOSE(op_stats, stats_type_items);
		EXPOSE(op_stats, stats_type_slabs);
		EXPOSE(op_stats, stats_type_sizes);
		EXPOSE(op_stats, stats_type_threads);
		EXPOSE(op_stats, stats_type_threads_request);
		EXPOSE(op_stats, stats_type_threads_slave);
		EXPOSE(op_stats, stats_type_nodes);
		EXPOSE(op_stats, stats_type_threads_queue);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_stats op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(test_op_stats::stats_type_default, op._stats_type);
	}

TEST_PARSE_TEXT_SERVER_PARAMETERS(items);
TEST_PARSE_TEXT_SERVER_PARAMETERS(slabs);
TEST_PARSE_TEXT_SERVER_PARAMETERS(sizes);
TEST_PARSE_TEXT_SERVER_PARAMETERS(threads);
TEST_PARSE_TEXT_SERVER_PARAMETERS2(threads, request);
TEST_PARSE_TEXT_SERVER_PARAMETERS2(threads, slave);
TEST_PARSE_TEXT_SERVER_PARAMETERS2(threads, queue);
TEST_PARSE_TEXT_SERVER_PARAMETERS(nodes);

	void test_parse_text_server_parameters_error()
	{
		shared_connection c(new connection_sstream(" hogehoge\r\n"));
		test_op_stats op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
		cut_assert_equal_int(test_op_stats::stats_type_error, op._stats_type);
	}

	void test_parse_binary_server_parameters_empty()
	{
		binary_request_header header(binary_header::opcode_stat);
		shared_connection c(new connection_sstream(header, NULL));
		test_op_stats op(c);
		cut_assert_equal_int(0, op._parse_binary_server_parameters());
		cut_assert_equal_int(test_op_stats::stats_type_default, op._stats_type);
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

TEST_PARSE_BINARY_SERVER_PARAMETERS(items);
TEST_PARSE_BINARY_SERVER_PARAMETERS(slabs);
TEST_PARSE_BINARY_SERVER_PARAMETERS(sizes);
TEST_PARSE_BINARY_SERVER_PARAMETERS(threads);
TEST_PARSE_BINARY_SERVER_PARAMETERS2(threads, request);
TEST_PARSE_BINARY_SERVER_PARAMETERS2(threads, slave);
TEST_PARSE_BINARY_SERVER_PARAMETERS2(threads, queue);
TEST_PARSE_BINARY_SERVER_PARAMETERS(nodes);

	void test_parse_binary_server_parameters_error()
	{
		binary_request_header header(binary_header::opcode_stat);
		header.set_total_body_length(8);
		shared_connection c(new connection_sstream(header, "hogehoge"));
		test_op_stats op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		cut_assert_equal_int(test_op_stats::stats_type_error, op._stats_type);
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
