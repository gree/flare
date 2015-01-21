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
 *	test_op_node_state.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_node_state.h>

using namespace gree::flare;

namespace test_op_node_state
{
	TEST_OP_CLASS_BEGIN(op_node_state, NULL)
		EXPOSE(op_node_state, _node_server_name);
		EXPOSE(op_node_state, _node_server_port);
		EXPOSE(op_node_state, _node_state);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_node_state op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_hostname_port()
	{
		shared_connection c(new connection_sstream(" localhost 12121\r\n"));
		test_op_node_state op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_hostname_port_states()
	{
		{
			shared_connection c(new connection_sstream(" localhost 12121 active\r\n"));
			test_op_node_state op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("localhost", op._node_server_name.c_str());
			cut_assert_equal_int(12121, op._node_server_port);
			cut_assert_equal_int(cluster::state_active, op._node_state);
		}
		{
			shared_connection c(new connection_sstream(" localhost 12121 prepare\r\n"));
			test_op_node_state op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("localhost", op._node_server_name.c_str());
			cut_assert_equal_int(12121, op._node_server_port);
			cut_assert_equal_int(cluster::state_prepare, op._node_state);
		}
		{
			shared_connection c(new connection_sstream(" localhost 12121 down\r\n"));
			test_op_node_state op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("localhost", op._node_server_name.c_str());
			cut_assert_equal_int(12121, op._node_server_port);
			cut_assert_equal_int(cluster::state_down, op._node_state);
		}
		{
			shared_connection c(new connection_sstream(" localhost 12121 ready\r\n"));
			test_op_node_state op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("localhost", op._node_server_name.c_str());
			cut_assert_equal_int(12121, op._node_server_port);
			cut_assert_equal_int(cluster::state_ready, op._node_state);
		}
		{
			shared_connection c(new connection_sstream(" localhost 12121 unknown\r\n"));
			test_op_node_state op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
	}

	void test_parse_text_server_parameters_hostname_port_state_garbage()
	{
		shared_connection c(new connection_sstream(" localhost 12121 active garbage\r\n"));
		test_op_node_state op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
