/**
 *	test_connection_iostream.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "common_connection_tests.h"
#include <app.h>
#include <connection_iostream.h>

#include <iostream>

using namespace gree::flare;

namespace test_connection_iostream
{
	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	connection* connection_iostream_factory(const std::string& input)
	{
		return new connection_sstream(input);
	}

	COMMON_CONNECTION_TEST(connection_iostream, readsize_basic);
	COMMON_CONNECTION_TEST(connection_iostream, readsize_zero);
	COMMON_CONNECTION_TEST(connection_iostream, readsize_empty);
	COMMON_CONNECTION_TEST(connection_iostream, readline_basic);
	COMMON_CONNECTION_TEST(connection_iostream, readline_unix);
	COMMON_CONNECTION_TEST(connection_iostream, push_back_basic);
	
	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
