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
 *	test_op_keys.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_keys.h>

using namespace gree::flare;

namespace test_op_keys
{
	TEST_OP_CLASS_BEGIN(op_keys, NULL, NULL)
		EXPOSE(op_keys, _entry_list);
		EXPOSE(op_keys, _parameter);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_keys op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_key_only()
	{
		shared_connection c(new connection_sstream(" key\r\n"));
		test_op_keys op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_keys_limit()
	{
		shared_connection c(new connection_sstream(" key1 key2 5\r\n"));
		test_op_keys op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_uint(2, op._entry_list.size());
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
			}
		}
		cut_assert_equal_int(5,
				static_cast<int>(reinterpret_cast<long>(op._parameter)));
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
