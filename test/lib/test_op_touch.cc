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
 *	test_op_touch.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_touch.h>
#include <binary_request_header.h>

using namespace gree::flare;

namespace test_op_touch
{
	TEST_OP_CLASS_BEGIN(op_touch, NULL, NULL)
		EXPOSE(op, _parse_binary_server_parameters);
		EXPOSE(op_touch, _entry);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_touch op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_key_only()
	{
		shared_connection c(new connection_sstream(" key\r\n"));
		test_op_touch op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_key_expiration()
	{
		stats_object->update_timestamp(0);
		shared_connection c(new connection_sstream(" key 3600\r\n"));
		test_op_touch op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_string("key", op._entry.key.c_str());
		cut_assert_equal_double(stats_object->get_timestamp() + 3600, 2, op._entry.expire);
		cut_assert_equal_int(storage::option_none, op._entry.option);
	}

	void test_parse_text_server_parameters_key_expiration_options()
	{
		{
			stats_object->update_timestamp(0);
			shared_connection c(new connection_sstream(" key 3600 noreply\r\n"));
			test_op_touch op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("key", op._entry.key.c_str());
			cut_assert_equal_double(stats_object->get_timestamp() + 3600, 2, op._entry.expire);
			cut_assert_equal_int(storage::option_noreply, op._entry.option);
		}
		{
			// Sync is not supported in flush
			stats_object->update_timestamp(0);
			shared_connection c(new connection_sstream(" key 3600 sync\r\n"));
			test_op_touch op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
		{
			// ... Nor is async
			stats_object->update_timestamp(0);
			shared_connection c(new connection_sstream(" key 3600 async\r\n"));
			test_op_touch op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
		{
			// ... Nor any combination
			stats_object->update_timestamp(0);
			shared_connection c(new connection_sstream(" key 3600 noreply async\r\n"));
			test_op_touch op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
	}

	void test_parse_binary_server_parameters_empty() {
		binary_request_header header(binary_header::opcode_touch);
		shared_connection c(new connection_sstream(header, NULL));
		test_op_touch op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_extras() {
		binary_request_header header(binary_header::opcode_touch);
		header.set_key_length(5);
		header.set_extras_length(8);
		header.set_total_body_length(13);
		header.set_cas(0);
		shared_connection c(new connection_sstream(header, "\x00\x00\x00\x00\x00\x00\x00\x00""touch"));
		test_op_touch op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_basic() {
		binary_request_header header(binary_header::opcode_touch);
		header.set_key_length(5);
		header.set_extras_length(4);
		header.set_total_body_length(9);
		shared_connection c(new connection_sstream(header, "\x00\x00\x0E\x10""touch")); // 0xE10 = 3600
		test_op_touch op(c);
		cut_assert_equal_int(0, op._parse_binary_server_parameters());
		cut_assert_equal_string("touch", op._entry.key.c_str());
		cut_assert_equal_double(stats_object->get_timestamp() + 3600, 2, op._entry.expire);
		cut_assert_equal_int(0, op._entry.size);
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_run_client_basic() {
		storage::entry input;
		input.key = "key";
		input.expire = util::realtime(3600); // now + 1h

		std::ostringstream expected;
		expected << "touch " << input.key << ' ' << input.expire << line_delimiter;

		shared_connection c(new connection_sstream(std::string()));
		test_op_touch op(c);
		cut_assert_equal_int(0, op._run_client(input));

		cut_assert_equal_string(expected.str().c_str(),
				static_cast<const connection_sstream&>(*c).get_output().c_str());
	}

	void test_run_client_noreply() {
		storage::entry input;
		input.key = "key";
		input.expire = util::realtime(3600); // now + 1h
		input.option = storage::option_noreply;

		std::ostringstream expected;
		expected << "touch " << input.key << ' ' << input.expire << ' ' << storage::option_cast(storage::option_noreply) << line_delimiter;

		shared_connection c(new connection_sstream(std::string()));
		test_op_touch op(c);
		cut_assert_equal_int(0, op._run_client(input));

		cut_assert_equal_string(expected.str().c_str(),
				static_cast<const connection_sstream&>(*c).get_output().c_str());
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
