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
 *	test_op.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op.h>
#include <binary_response_header.h>

#include <sstream>

using namespace gree::flare;

namespace test_op
{
	TEST_OP_CLASS_BEGIN(op, std::string(), binary_header::opcode_noop)
		EXPOSE(op, _connection);
		EXPOSE(op, _opcode);
		EXPOSE(op, _quiet);
		EXPOSE(op, _send_binary_result);
	TEST_OP_CLASS_END;

	test_op* op_object = NULL;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		op_object = new test_op(shared_connection(new connection_sstream(std::string())));
	}

	void check_send_binary_result_standard(op& op_instance, op::result input_result, const char* input_message,
			binary_header::status expected_status, const char* expected_message) {
		const connection_sstream* connection = dynamic_cast<const connection_sstream*>(&*static_cast<test_op&>(static_cast<op&>(op_instance))._connection);
		if (connection) {
			binary_response_header expected_header(static_cast<const test_op&>(static_cast<op&>(op_instance))._opcode);
			expected_header.set_status(expected_status);
			if (expected_message) {
				expected_header.set_total_body_length(strlen(expected_message));
			}
			std::ostringstream expected_os;
			expected_os.write(expected_header.get_raw_data(), expected_header.get_raw_size());
			if (expected_message) {
				expected_os.write(expected_message, strlen(expected_message));
			}
			cut_assert_equal_int(expected_header.get_raw_size() + expected_header.get_total_body_length(),
				      static_cast<test_op&>(static_cast<op&>(op_instance))._send_binary_result(input_result, input_message));
			std::string binary_output = connection->get_output();
			cut_assert_equal_memory(expected_os.str().data(), expected_os.str().size(), binary_output.data(), binary_output.size());
		}
	}

	void check_send_quiet_binary_result_silent(op& op_instance, op::result input_result, const char* input_message) {
		const connection_sstream* connection = dynamic_cast<const connection_sstream*>(&*static_cast<test_op&>(static_cast<op&>(op_instance))._connection);
		cut_assert_not_null(connection);
		if (connection) {
			cut_assert_equal_int(0, static_cast<test_op&>(static_cast<op&>(op_instance))._send_binary_result(input_result, input_message));
			cut_assert_equal_int(0, connection->get_output().size());
		}
	}

#define TEST_BINARY_STANDARD_RESPONSE(test_op_type, name, expected_status, expected_message) \
	void test_send_binary_result_##name() { \
		test_op_type op(shared_connection(new connection_sstream(std::string()))); \
		check_send_binary_result_standard(op, op::result_##name, NULL, expected_status, expected_message); \
	}

#define TEST_QUIET_BINARY_SILENT_RESPONSE(test_op_type, name) \
	void test_send_quiet_binary_result_##name##_silent() { \
		test_op_type op(shared_connection(new connection_sstream(std::string()))); \
		const_cast<bool&>(op._quiet) = true; \
		check_send_quiet_binary_result_silent(op, op::result_##name, NULL); \
	}

#define TEST_QUIET_BINARY_STANDARD_RESPONSE(test_op_type, name, expected_status, expected_message) \
	void test_send_quiet_binary_result_##name() { \
		test_op_type op(shared_connection(new connection_sstream(std::string()))); \
		const_cast<bool&>(op._quiet) = true; \
		check_send_binary_result_standard(op, op::result_##name, NULL, expected_status, expected_message); \
	}

TEST_BINARY_STANDARD_RESPONSE(test_op, none, binary_header::status_no_error, NULL);
TEST_BINARY_STANDARD_RESPONSE(test_op, ok, binary_header::status_no_error, NULL);
TEST_BINARY_STANDARD_RESPONSE(test_op, end, binary_header::status_no_error, NULL);
TEST_BINARY_STANDARD_RESPONSE(test_op, stored, binary_header::status_no_error, NULL);
TEST_BINARY_STANDARD_RESPONSE(test_op, deleted, binary_header::status_no_error, NULL);
TEST_BINARY_STANDARD_RESPONSE(test_op, found, binary_header::status_no_error, NULL);
TEST_BINARY_STANDARD_RESPONSE(test_op, touched, binary_header::status_no_error, NULL);
TEST_BINARY_STANDARD_RESPONSE(test_op, not_stored, binary_header::status_item_not_stored, "Item not stored");
TEST_BINARY_STANDARD_RESPONSE(test_op, exists, binary_header::status_key_exists, "Key exists");
TEST_BINARY_STANDARD_RESPONSE(test_op, not_found, binary_header::status_key_not_found, "Not found");
TEST_QUIET_BINARY_SILENT_RESPONSE(test_op, none);
TEST_QUIET_BINARY_SILENT_RESPONSE(test_op, ok);
TEST_QUIET_BINARY_SILENT_RESPONSE(test_op, end);
TEST_QUIET_BINARY_SILENT_RESPONSE(test_op, stored);
TEST_QUIET_BINARY_SILENT_RESPONSE(test_op, deleted);
TEST_QUIET_BINARY_SILENT_RESPONSE(test_op, found);
TEST_QUIET_BINARY_SILENT_RESPONSE(test_op, touched);
TEST_QUIET_BINARY_STANDARD_RESPONSE(test_op, not_stored, binary_header::status_item_not_stored, "Item not stored");
TEST_QUIET_BINARY_STANDARD_RESPONSE(test_op, exists, binary_header::status_key_exists, "Key exists");
TEST_QUIET_BINARY_STANDARD_RESPONSE(test_op, not_found, binary_header::status_key_not_found, "Not found");

	void teardown()
	{
		delete stats_object;
		delete op_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
