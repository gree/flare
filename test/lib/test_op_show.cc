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
 *	test_op_show.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_show.h>

using namespace gree::flare;

namespace test_op_show
{
	TEST_OP_CLASS_BEGIN(op_show)
		EXPOSE(op_show, _show_type);
		EXPOSE(op_show, show_type_error);
		EXPOSE(op_show, show_type_variables);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_show op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
		cut_assert_equal_int(test_op_show::show_type_error, op._show_type);
	}

	void test_parse_text_server_parameters_variables()
	{
		shared_connection c(new connection_sstream(" variables\r\n"));
		test_op_show op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_int(test_op_show::show_type_variables, op._show_type);
	}

	void test_parse_text_server_parameters_error()
	{
		shared_connection c(new connection_sstream(" anything\r\n"));
		test_op_show op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
		cut_assert_equal_int(test_op_show::show_type_error, op._show_type);
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
