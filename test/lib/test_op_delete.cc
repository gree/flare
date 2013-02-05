/**
 *	test_op_delete.cc
 *
 *	Note: More exhaustive parser tests are performed in test_storage_entry.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_delete.h>
#include <binary_request_header.h>

using namespace gree::flare;

namespace test_op_delete
{
	TEST_OP_CLASS_BEGIN(op_delete, NULL, NULL)
		EXPOSE(op, _parse_binary_server_parameters);
		EXPOSE(op_delete, _entry);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_delete op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_key_expiration_version_options()
	{
		shared_connection c(new connection_sstream(" key 10 1 noreply sync\r\n"));
		test_op_delete op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_equal_string("key", op._entry.key.c_str());
		cut_assert_equal_double(stats_object->get_timestamp() + 10, 2, op._entry.expire);
		cut_assert_equal_int(storage::option_noreply | storage::option_sync, op._entry.option);
	}

	void test_parse_binary_server_parameters_empty()
	{
		binary_request_header header(binary_header::opcode_delete);
		shared_connection c(new connection_sstream(header, NULL));
		test_op_delete op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_extras()
	{
		binary_request_header header(binary_header::opcode_delete);
		header.set_extras_length(4);
		header.set_key_length(6);
		header.set_total_body_length(10);
		shared_connection c(new connection_sstream(header, "\xAD\xDE\xAD\xDE""delete"));
		test_op_delete op(c);
		cut_assert_equal_int(-1, op._parse_binary_server_parameters());
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void test_parse_binary_server_parameters_basic()
	{
		binary_request_header header(binary_header::opcode_delete);
		header.set_key_length(6);
		header.set_total_body_length(6);
		shared_connection c(new connection_sstream(header, "delete"));
		test_op_delete op(c);
		cut_assert_equal_int(0, op._parse_binary_server_parameters());
		cut_assert_equal_string("delete", op._entry.key.c_str());
		cut_assert_equal_int(0, op._entry.size);
		char* dummy;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
