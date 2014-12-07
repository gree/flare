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
 *	test_op_node_role.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_node_role.h>

using namespace gree::flare;

namespace test_op_node_role
{
	TEST_OP_CLASS_BEGIN(op_node_role, NULL)
		EXPOSE(op_node_role, _node_server_name);
		EXPOSE(op_node_role, _node_server_port);
		EXPOSE(op_node_role, _node_role);
		EXPOSE(op_node_role, _node_balance);
		EXPOSE(op_node_role, _node_partition);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_node_role op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_hostname_port()
	{
		shared_connection c(new connection_sstream(" localhost 12121\r\n"));
		test_op_node_role op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_hostname_roles()
	{
		{
			shared_connection c(new connection_sstream(" localhost 12121 master\r\n"));
			test_op_node_role op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("localhost", op._node_server_name.c_str());
			cut_assert_equal_int(12121, op._node_server_port);
			cut_assert_equal_int(cluster::role_master, op._node_role);
			cut_assert_equal_int(-1, op._node_balance);
			cut_assert_equal_int(-1, op._node_partition);
		}
		{
			shared_connection c(new connection_sstream(" localhost 12121 slave\r\n"));
			test_op_node_role op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("localhost", op._node_server_name.c_str());
			cut_assert_equal_int(12121, op._node_server_port);
			cut_assert_equal_int(cluster::role_slave, op._node_role);
			cut_assert_equal_int(-1, op._node_balance);
			cut_assert_equal_int(-1, op._node_partition);
		}
		{
			shared_connection c(new connection_sstream(" localhost 12121 proxy\r\n"));
			test_op_node_role op(c);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("localhost", op._node_server_name.c_str());
			cut_assert_equal_int(12121, op._node_server_port);
			cut_assert_equal_int(cluster::role_proxy, op._node_role);
			cut_assert_equal_int(-1, op._node_balance);
			cut_assert_equal_int(-1, op._node_partition);
		}
		{
			shared_connection c(new connection_sstream(" localhost 12121 unknown\r\n"));
			test_op_node_role op(c);
			cut_assert_equal_int(-1, op._parse_text_server_parameters());
		}
	}

	void test_parse_text_server_parameters_hostname_role_balance()
	{
		shared_connection c(new connection_sstream(" localhost 12121 master 1\r\n"));
		test_op_node_role op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_string("localhost", op._node_server_name.c_str());
		cut_assert_equal_int(12121, op._node_server_port);
		cut_assert_equal_int(cluster::role_master, op._node_role);
		cut_assert_equal_int(1, op._node_balance);
		cut_assert_equal_int(-1, op._node_partition);
	}

	void test_parse_text_server_parameters_hostname_role_balance_partition()
	{
		shared_connection c(new connection_sstream(" localhost 12121 master 1 1\r\n"));
		test_op_node_role op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_string("localhost", op._node_server_name.c_str());
		cut_assert_equal_int(12121, op._node_server_port);
		cut_assert_equal_int(cluster::role_master, op._node_role);
		cut_assert_equal_int(1, op._node_balance);
		cut_assert_equal_int(1, op._node_partition);
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
