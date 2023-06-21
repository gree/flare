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
 *	test_op_set.cc
 *
 *	Note: More exhaustive parser tests are performed in test_storage_entry.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_set.h>
#include <binary_request_header.h>

#include <boost/predef/other/endian.h>

using namespace gree::flare;

namespace test_op_set
{
	TEST_OP_CLASS_BEGIN(op_set, NULL, NULL)
		EXPOSE(op, _parse_binary_server_parameters);
		EXPOSE(op_set, _entry);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_set op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters()
	{
		stats_object->update_timestamp();
		shared_connection c(new connection_sstream(" key 5 60 10 \r\n0123456789\r\n"));
		test_op_set op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_string("key", op._entry.key.c_str());
		cut_assert_equal_double(stats_object->get_timestamp() + 60, 2, op._entry.expire);
		cut_assert_equal_int(10, op._entry.size);
		cut_assert_equal_memory("0123456789", 10, op._entry.data.get(), 10);
	}

	void test_parse_binary_server_parameters_empty()
	{
		binary_request_header header(binary_header::opcode_set);
		shared_connection c(new connection_sstream(header, NULL));
		test_op_set op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_missing_extras()
	{
		binary_request_header header(binary_header::opcode_set);
		header.set_key_length(3);
		header.set_total_body_length(8);
		shared_connection c(new connection_sstream(header, "setvalue"));
		test_op_set op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_basic()
	{
		binary_request_header header(binary_header::opcode_set);
		header.set_key_length(3);
		header.set_extras_length(8);
		header.set_total_body_length(16);
		header.set_cas(5);
		shared_connection c(new connection_sstream(header, "\x00\x00\x00\x01\x00\x00\x00\x3Csetvalue"));
		test_op_set op(c);
		cut_assert_equal_int(0, op._parse_binary_server_parameters());
		cut_assert_equal_string("set", op._entry.key.c_str());
		cut_assert_equal_int(1, op._entry.flag);
		cut_assert_equal_double(stats_object->get_timestamp() + 60, 2, op._entry.expire);
		cut_assert_equal_int(5, op._entry.size);
		cut_assert_equal_int(5, op._entry.version);
		cut_assert_equal_memory("value", 5, op._entry.data.get(), 5);
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
