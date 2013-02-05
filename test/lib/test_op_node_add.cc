/**
 *	test_op_node_add.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_node_add.h>

using namespace gree::flare;

namespace test_op_node_add
{
	TEST_OP_CLASS_BEGIN(op_node_add, NULL)
		EXPOSE(op_node_add, _node_server_name);
		EXPOSE(op_node_add, _node_server_port);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_node_add op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_hostname_port()
	{
		shared_connection c(new connection_sstream(" localhost 12121\r\n"));
		test_op_node_add op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_string("localhost", op._node_server_name.c_str());
		cut_assert_equal_int(12121, op._node_server_port);
	}

	void test_parse_text_server_parameters_hostname_port_garbage()
	{
		shared_connection c(new connection_sstream(" localhost 12121 garbage\r\n"));
		test_op_node_add op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
