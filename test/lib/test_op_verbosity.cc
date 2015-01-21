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
 *	test_op_verbosity.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_verbosity.h>

using namespace gree::flare;

namespace test_op_verbosity
{
	TEST_OP_CLASS_BEGIN(op_verbosity)
		EXPOSE(op_verbosity, _verbosity);
		EXPOSE(op_verbosity, _option);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_verbosity op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_verbosity()
	{
		shared_connection c(new connection_sstream(" 2\r\n"));
		test_op_verbosity op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(2, op._verbosity);
		cut_assert_equal_int(storage::option_none, op._option);
	}

	void test_parse_text_server_parameters_verbosity_options()
	{
		{
			// Noreply
			shared_connection c(new connection_sstream(" 2 noreply\r\n"));
			test_op_verbosity op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(2, op._verbosity);
			cut_assert_equal_int(storage::option_noreply, op._option);
		}
		{
			// Sync is not supported by this op
			shared_connection c(new connection_sstream(" 2 sync\r\n"));
			test_op_verbosity op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
		{
			// Async
			shared_connection c(new connection_sstream(" 2 async\r\n"));
			test_op_verbosity op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(2, op._verbosity);
			cut_assert_equal_int(storage::option_async, op._option);
		}
		{
			// Noreply + Async
			shared_connection c(new connection_sstream(" 2 noreply async\r\n"));
			test_op_verbosity op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(2, op._verbosity);
			cut_assert_equal_int(storage::option_noreply | storage::option_async, op._option);
		}
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
