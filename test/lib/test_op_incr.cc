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
 *	test_op_incr.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_incr.h>
#include <binary_request_header.h>

using namespace gree::flare;

namespace test_op_incr
{
	TEST_OP_CLASS_BEGIN(op_incr, NULL, NULL)
		EXPOSE(op, _parse_binary_server_parameters);
		EXPOSE(op_incr, _entry);
		EXPOSE(op_incr, _value);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_incr op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_key_value()
	{
		shared_connection c(new connection_sstream(" key 1\r\n"));
		test_op_incr op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_string("key", op._entry.key.c_str());
		cut_assert_equal_int(1, op._value);
		cut_assert_equal_int(storage::option_none, op._entry.option);
	}

	void test_parse_text_server_parameters_key_value_entry_option()
	{
		{
			shared_connection c(new connection_sstream(" key 1 noreply\r\n"));
			test_op_incr op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("key", op._entry.key.c_str());
			cut_assert_equal_int(1, op._value);
			cut_assert_equal_int(storage::option_noreply, op._entry.option);
		}
		{
			shared_connection c(new connection_sstream(" key 1 sync\r\n"));
			test_op_incr op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("key", op._entry.key.c_str());
			cut_assert_equal_int(1, op._value);
			cut_assert_equal_int(storage::option_sync, op._entry.option);
		}
		{
			shared_connection c(new connection_sstream(" key 1 async\r\n"));
			test_op_incr op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("key", op._entry.key.c_str());
			cut_assert_equal_int(1, op._value);
			cut_assert_equal_int(storage::option_async, op._entry.option);
		}
		{
			shared_connection c(new connection_sstream(" key 1 noreply async\r\n"));
			test_op_incr op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("key", op._entry.key.c_str());
			cut_assert_equal_int(1, op._value);
			cut_assert_equal_int(storage::option_noreply | storage::option_async, op._entry.option);
		}
	}

	void test_parse_binary_server_parameters_empty() {
		binary_request_header header(binary_header::opcode_increment);
		shared_connection c(new connection_sstream(header, NULL));
		test_op_incr op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_missing_extras() {
		binary_request_header header(binary_header::opcode_increment);
		header.set_key_length(4);
		header.set_total_body_length(4);
		shared_connection c(new connection_sstream(header, "incr"));
		test_op_incr op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_basic() {
		binary_request_header header(binary_header::opcode_increment);
		header.set_extras_length(20);
		header.set_key_length(4);
		header.set_total_body_length(24);
		// Value = 1 / Initial value = 5 / Expiration = 0xffffffff (ignore initial value)
		shared_connection c(new connection_sstream(header, "\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x05\xFF\xFF\xFF\xFFincr"));
		test_op_incr op(c);
		cut_assert_equal_int(0, op._parse_binary_server_parameters());
		cut_assert_equal_string("incr", op._entry.key.c_str());
		cut_assert_equal_int(0, op._entry.expire);
		cut_assert_equal_int(0, op._entry.size);
		cut_assert_equal_int(1, op._value);
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_initial_value() {
		binary_request_header header(binary_header::opcode_increment);
		header.set_extras_length(20);
		header.set_key_length(4);
		header.set_total_body_length(24);
		// Value = 1 / Initial value = 5 / Expiration = 3600
		shared_connection c(new connection_sstream(header, "\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x0E\x10incr"));
		test_op_incr op(c);
		cut_assert_equal_int(0, op._parse_binary_server_parameters());
		cut_assert_equal_string("incr", op._entry.key.c_str());
		cut_assert_equal_double(stats_object->get_timestamp() + 3600, 2, op._entry.expire);
		cut_assert_equal_int(1, op._entry.size);
		cut_assert_equal_memory("5", 1, op._entry.data.get(), 1);
		cut_assert_equal_int(1, op._value);
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
