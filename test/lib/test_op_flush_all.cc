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
 *	test_op_flush_all.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_flush_all.h>

using namespace gree::flare;

namespace test_op_flush_all
{
	TEST_OP_CLASS_BEGIN(op_flush_all, NULL)
		EXPOSE(op_flush_all, _expire);
		EXPOSE(op_flush_all, _option);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_flush_all op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(0, op._expire);
		cut_assert_equal_int(0, op._option);
	}

	void test_parse_text_server_parameters_expiration()
	{
		stats_object->update_timestamp(0);
		shared_connection c(new connection_sstream(" 10\r\n"));
		test_op_flush_all op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(10, op._expire);
		cut_assert_equal_int(0, op._option);
	}

	void test_parse_text_server_parameters_expiration_options()
	{
		{
			stats_object->update_timestamp(0);
			shared_connection c(new connection_sstream(" 10 noreply\r\n"));
			test_op_flush_all op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(10, op._expire);
			cut_assert_equal_int(storage::option_noreply, op._option);
		}
		{
			// Sync is not supported in flush
			stats_object->update_timestamp(0);
			shared_connection c(new connection_sstream(" 10 sync\r\n"));
			test_op_flush_all op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
		{
			stats_object->update_timestamp(0);
			shared_connection c(new connection_sstream(" 10 async\r\n"));
			test_op_flush_all op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(10, op._expire);
			cut_assert_equal_int(storage::option_async, op._option);
		}
		{
			stats_object->update_timestamp(0);
			shared_connection c(new connection_sstream(" 10 noreply async\r\n"));
			test_op_flush_all op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_int(10, op._expire);
			cut_assert_equal_int(storage::option_noreply | storage::option_async, op._option);
		}
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
