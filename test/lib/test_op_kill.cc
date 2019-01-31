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
 *	test_op_kill.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_kill.h>

using namespace gree::flare;

namespace test_op_kill
{
	TEST_OP_CLASS_BEGIN(op_kill, NULL, NULL)
		EXPOSE(op_kill, _id);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_kill op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_id()
	{
		shared_connection c(new connection_sstream(" 1\r\n"));
		test_op_kill op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(1, op._id);
	}

	void test_parse_text_server_parameters_id_fail()
	{
		shared_connection c(new connection_sstream(" id\r\n"));
		test_op_kill op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_id_garbage()
	{
		shared_connection c(new connection_sstream(" 1 garbage\r\n"));
		test_op_kill op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
