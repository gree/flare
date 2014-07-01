/**
 *	test_op_gat.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_gat.h>
#include <binary_request_header.h>

using namespace gree::flare;

namespace test_op_gat
{
	TEST_OP_CLASS_BEGIN(op_gat, NULL, NULL)
		EXPOSE(op_set, _entry);
		EXPOSE(op_gat, _send_text_result);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_run_client_basic() {
		storage::entry input;
		input.key = "key";
		input.expire = util::realtime(3600); // now + 1h

		std::ostringstream expected;
		expected << "gat " << input.key << ' ' << input.expire << line_delimiter;

		shared_connection c(new connection_sstream(std::string()));
		test_op_gat op(c);
		cut_assert_equal_int(0, op._run_client(input));

		cut_assert_equal_string(expected.str().c_str(),
				static_cast<const connection_sstream&>(*c).get_output().c_str());
	}

	void test_run_client_noreply() {
		storage::entry input;
		input.key = "key";
		input.expire = util::realtime(3600); // now + 1h
		input.option = storage::option_noreply;

		std::ostringstream expected;
		expected << "gat " << input.key << ' ' << input.expire << ' ' << storage::option_cast(storage::option_noreply) << line_delimiter;

		shared_connection c(new connection_sstream(std::string()));
		test_op_gat op(c);
		cut_assert_equal_int(0, op._run_client(input));

		cut_assert_equal_string(expected.str().c_str(),
				static_cast<const connection_sstream&>(*c).get_output().c_str());
	}

	void test_parse_text_client_parameters_empty() {
		shared_connection c(new connection_sstream(std::string()));
		test_op_gat op(c);
		storage::entry entry;
		cut_assert_equal_int(-1, op._parse_text_client_parameters(entry));
		cut_assert_equal_int(storage::result_none, op._result);
	}

	void test_parse_text_client_parameters_not_found() {
		shared_connection c(new connection_sstream(storage::result_cast(storage::result_not_found)));
		test_op_gat op(c);
		storage::entry entry;
		cut_assert_equal_int(0, op._parse_text_client_parameters(entry));
		cut_assert_equal_int(storage::result_not_found, op._result);
	}

	void test_parse_text_client_parameters_garbage() {
		shared_connection c(new connection_sstream("garbage"));
		test_op_gat op(c);
		storage::entry entry;
		cut_assert_equal_int(-1, op._parse_text_client_parameters(entry));
		cut_assert_equal_int(storage::result_none, op._result);
	}

	void test_parse_text_client_parameters_wrong_key() {
		shared_connection c(new connection_sstream("VALUE wrong 5 5\r\nvalue\r\n"));
		test_op_gat op(c);
		storage::entry entry;
		entry.key = "key";
		cut_assert_equal_int(-1, op._parse_text_client_parameters(entry));
		cut_assert_equal_int(storage::result_none, op._result);
	}

	void test_parse_text_client_parameters_basic() {
		shared_connection c(new connection_sstream("VALUE key 5 5\r\nvalue\r\n"));
		test_op_gat op(c);
		storage::entry entry;
		entry.key = "key";
		cut_assert_equal_int(0, op._parse_text_client_parameters(entry));
		cut_assert_equal_int(storage::result_touched, op._result);
		cut_assert_equal_int(5, entry.flag);
		cut_assert_equal_int(5, entry.size);
		cut_assert_equal_memory("value", 5, entry.data.get(), entry.size);
	}

	void test_send_text_result_basic() {
		shared_connection c(new connection_sstream(std::string()));
		test_op_gat op(c);
		op._entry.key = "gat_key";
		op._entry.flag = 5;
		op._entry.expire = util::realtime(3600);
		op._entry.size = 9;
		op._entry.data = shared_byte(new uint8_t[op._entry.size]);
		memcpy(op._entry.data.get(), "gat_value", op._entry.size);
		const char* expected_msg = "VALUE gat_key 5 9\r\ngat_value\r\n";
		cut_assert_equal_int(strlen(expected_msg), op._send_text_result(op::result_touched, NULL));
		cut_assert_equal_string(expected_msg, static_cast<const connection_sstream&>(*c).get_output().c_str());
	}

	void test_send_text_result_not_found() {
		shared_connection c(new connection_sstream(std::string()));
		test_op_gat op(c);
		cut_assert_equal_int(0, op._send_text_result(op::result_not_found, NULL));
		cut_assert_equal_string("NOT_FOUND\r\n",
				static_cast<const connection_sstream&>(*c).get_output().c_str());
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
