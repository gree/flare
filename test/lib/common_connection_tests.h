/**
 *	common_connection_tests.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <connection.h>

using namespace gree::flare;

#define COMMON_CONNECTION_TEST(connection, testname) \
	void test_##connection##_##testname() { \
		test_connection::testname(&connection##_factory); \
	}

namespace test_connection
{
	typedef connection* (*connection_factory)(const std::string& input);

	// Common tests
	void readsize_basic(connection_factory);
	void readsize_zero(connection_factory);
	void readsize_empty(connection_factory);
	void readline_basic(connection_factory);
	void readline_unix(connection_factory);
	void push_back_basic(connection_factory);
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
