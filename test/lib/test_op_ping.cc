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
 *	test_op_ping.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_ping.h>

using namespace gree::flare;

namespace test_op_ping
{
	TEST_OP_CLASS_BEGIN(op_ping)
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		status_object = new status();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_ping op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_garbage()
	{
		shared_connection c(new connection_sstream(" garbage\r\n"));
		test_op_ping op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_run_server_status_ok()
	{
		shared_connection c(new connection_sstream(std::string()));
		connection_sstream& cstr = dynamic_cast<connection_sstream&>(*c);
		test_op_ping op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(0, op._run_server());
		cut_assert_equal_string("OK\r\n", cstr.get_output().c_str());
	}

	void test_run_server_status_ng()
	{
		status_object->set_status_code(status::status_ng);
		shared_connection c(new connection_sstream(std::string()));
		connection_sstream& cstr = dynamic_cast<connection_sstream&>(*c);
		test_op_ping op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(0, op._run_server());
		cut_assert_equal_string("SERVER_ERROR unknown error\r\n", cstr.get_output().c_str());
	}

	void teardown()
	{
		delete stats_object;
		delete status_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
