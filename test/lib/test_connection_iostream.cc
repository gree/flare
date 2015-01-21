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
