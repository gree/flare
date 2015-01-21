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
