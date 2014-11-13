/**
 *	test_queue_forward_query.cc
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 */
#include "app.h"
#include "op.h"
#include "op_delete.h"
#include "op_set.h"
#include "op_touch.h"
#include "queue_forward_query.h"
#include "logger.h"
#include "storage.h"

#include "connection_iostream.h"

#include <cppcutter.h>

using std::string;
using namespace gree::flare;

namespace test_queue_forward_query {
	struct queue_forward_query_test : public queue_forward_query {
		queue_forward_query_test(storage::entry e, string ident):
			queue_forward_query(e, ident) {
		}
		~queue_forward_query_test() {
		}
		op_proxy_write* get_op(string op_ident, shared_connection c) {
			return this->_get_op(op_ident, c);
		}
	};

	void setup() {
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void teardown() {
		delete stats_object;
	}

	storage::entry get_entry(string input, storage::parse_type type, string value) {
		storage::entry e;
		e.parse(input.c_str(), type);
		shared_byte data(new uint8_t[e.size]);
		memcpy(data.get(), value.c_str(), e.size);
		e.data = data;
		return e;
	}

	void check(queue_forward_query& q, bool success, op::result result, string message) {
		cut_assert_equal_boolean(success, q.is_success());
		cut_assert_equal_int(result, q.get_result());
		cut_assert_equal_string(message.c_str(), q.get_result_message().c_str());
	}

	void get_op_test(string ident) {
		// prepare
		storage::entry e;
		shared_connection c(new connection_sstream(""));
		queue_forward_query_test q(e, ident);

		// execute
		op* p = q.get_op(ident, c);

		// assert
		if (ident == "add"
			|| ident == "append"
			|| ident == "cas"
			|| ident == "decr"
			|| ident == "gat"
			|| ident == "incr"
			|| ident == "prepend"
			|| ident == "replace"
			|| ident == "set"
			|| ident == "touch") {
			cut_assert_not_null(p);
			cut_assert_not_null(dynamic_cast<op_set*>(p));
		} else if (ident == "delete") {
			cut_assert_not_null(p);
			cut_assert_not_null(dynamic_cast<op_delete*>(p));
		} else {
			cut_assert_null(p);
		}

		if (p) {
			delete p;
		}
	}

	void test_run_success() {
		// prepare
		storage::entry e = get_entry(" key 0 0 5 3", storage::parse_type_set, "VALUE");
		shared_connection c(new connection_sstream("STORED\r\n"));

		// execute
		queue_forward_query q(e, "set");
		cut_assert_equal_int(0, q.run(c));

		// assert
		check(q, true, op::result_stored, "");
	}

	void test_run_failure_by_unavailable_connection() {
		// prepare
		storage::entry e = get_entry(" key 0 0 5 3", storage::parse_type_set, "VALUE");
		shared_connection c(new connection_tcp("localhost", 10000));

		// execute
		queue_forward_query q(e, "set");
		cut_assert_equal_int(-1, q.run(c));

		// assert
		check(q, false, op::result_none, "");
	}

#define GET_OP_TEST(ident) \
	void test_get_op_##ident() { \
		get_op_test("ident"); \
	}

GET_OP_TEST(add)
GET_OP_TEST(append)
GET_OP_TEST(cas)
GET_OP_TEST(decr)
GET_OP_TEST(delete)
GET_OP_TEST(dump)
GET_OP_TEST(dump_key)
GET_OP_TEST(error)
GET_OP_TEST(flush_all)
GET_OP_TEST(gat)
GET_OP_TEST(get)
GET_OP_TEST(getk)
GET_OP_TEST(gets)
GET_OP_TEST(incr)
GET_OP_TEST(keys)
GET_OP_TEST(kill)
GET_OP_TEST(meta)
GET_OP_TEST(node_add)
GET_OP_TEST(node_remove)
GET_OP_TEST(node_role)
GET_OP_TEST(node_state)
GET_OP_TEST(node_sync)
GET_OP_TEST(parser)
GET_OP_TEST(parser_binary)
GET_OP_TEST(parser_text)
GET_OP_TEST(ping)
GET_OP_TEST(prepend)
GET_OP_TEST(proxy_read)
GET_OP_TEST(proxy_write)
GET_OP_TEST(replace)
GET_OP_TEST(set)
GET_OP_TEST(show)
GET_OP_TEST(show_node)
GET_OP_TEST(show_index)
GET_OP_TEST(shutdown)
GET_OP_TEST(stats)
GET_OP_TEST(stats_node)
GET_OP_TEST(stats_index)
GET_OP_TEST(touch)
GET_OP_TEST(verbosity)
GET_OP_TEST(version)

}
