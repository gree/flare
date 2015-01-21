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
 *	test_op_get.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_get.h>
#include <binary_request_header.h>

using namespace gree::flare;

namespace test_op_get
{
	TEST_OP_CLASS_BEGIN(op_get, NULL, NULL)
		EXPOSE(op, _parse_binary_server_parameters);
		EXPOSE(op_get, _entry_list);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_get op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
		cut_assert_equal_uint(0, op._entry_list.size());
	}

	void test_parse_text_server_parameters_keys()
	{
		shared_connection c(new connection_sstream(" key1 key2 key3\r\n"));
		test_op_get op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_uint(3, op._entry_list.size());
		unsigned int index = 1;
		for (std::list<storage::entry>::const_iterator it_entry = op._entry_list.begin();
				it_entry != op._entry_list.end();
				++index, ++it_entry) {
			switch(index) {
				case 1:
					cut_assert_equal_string("key1", it_entry->key.c_str());
					break;
				case 2:
					cut_assert_equal_string("key2", it_entry->key.c_str());
					break;
				case 3:
					cut_assert_equal_string("key3", it_entry->key.c_str());
					break;
			}
		}
	}

	void test_parse_binary_server_parameters_empty() {
		binary_request_header header(binary_header::opcode_get);
		shared_connection c(new connection_sstream(header, NULL));
		test_op_get op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_extras() {
		binary_request_header header(binary_header::opcode_get);
		header.set_extras_length(4);
		header.set_key_length(3);
		header.set_total_body_length(7);
		shared_connection c(new connection_sstream(header, "\xAD\xDE\xAD\xDEget"));
		test_op_get op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_basic() {
		binary_request_header header(binary_header::opcode_get);
		header.set_key_length(3);
		header.set_total_body_length(3);
		header.set_cas(5);
		shared_connection c(new connection_sstream(header, "get"));
		test_op_get op(c);
		cut_assert_equal_int(0, op._parse_binary_server_parameters());
		const storage::entry& entry = *op._entry_list.begin();
		cut_assert_equal_string("get", entry.key.c_str());
		cut_assert_equal_int(0, entry.flag);
		cut_assert_equal_int(0, entry.expire);
		cut_assert_equal_int(0, entry.size);
		cut_assert_equal_int(5, entry.version);
		cut_assert_equal_int(storage::option_none, entry.option);
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
