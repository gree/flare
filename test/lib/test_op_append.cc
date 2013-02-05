/**
 *	test_op_append.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_append.h>
#include <binary_request_header.h>

using namespace gree::flare;

namespace test_op_append
{
	TEST_OP_CLASS_BEGIN(op_append, NULL, NULL)
		EXPOSE(op, _parse_binary_server_parameters);
		EXPOSE(op_append, _entry);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	// Text parameter parsing is shared with op_set. Please refer to test_op_set.cc

	void test_parse_binary_server_parameters_empty() {
		binary_request_header header(binary_header::opcode_append);
		shared_connection c(new connection_sstream(header, NULL));
		test_op_append op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_extras() {
		binary_request_header header(binary_header::opcode_append);
		header.set_key_length(6);
		header.set_extras_length(11);
		header.set_total_body_length(19);
		header.set_cas(5);
		shared_connection c(new connection_sstream(header, "\x00\x00\x00\x01\x00\x00\x00\x3C""appendvalue"));
		test_op_append op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_basic() {
		binary_request_header header(binary_header::opcode_append);
		header.set_key_length(6);
		header.set_total_body_length(11);
		shared_connection c(new connection_sstream(header, "appendvalue"));
		test_op_append op(c);
		cut_assert_equal_int(0, op._parse_binary_server_parameters());
		cut_assert_equal_string("append", op._entry.key.c_str());
		cut_assert_equal_int(5, op._entry.size);
		cut_assert_equal_memory("value", 5, op._entry.data.get(), 5);
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
