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
 *	common_connection_tests.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include <common_connection_tests.h>

#include <util.h>

using namespace gree::flare;

namespace test_connection
{
	void readsize_basic(connection_factory factory)
	{
		shared_connection c((*factory)("123"));
		c->open();
		char* buffer;
		cut_assert_equal_int(1, c->readsize(1, &buffer));
		cut_assert_equal_char('1', buffer[0]);
		delete[] buffer;
		cut_assert_equal_int(1, c->readsize(1, &buffer));
		cut_assert_equal_char('2', buffer[0]);
		delete[] buffer;
		cut_assert_equal_int(1, c->readsize(1, &buffer));
		cut_assert_equal_char('3', buffer[0]);
		delete[] buffer;
	}

	void readsize_zero(connection_factory factory)
	{
		shared_connection c((*factory)("nothing to see here"));
		c->open();
		char* dummy = NULL;
		cut_assert_equal_int(0, c->readsize(0, &dummy));
		cut_assert_null(dummy);
		// Wedge connection
		c->readsize(BUFSIZ, &dummy);
		delete[] dummy;
	}

	void readsize_empty(connection_factory factory)
	{
		shared_connection c((*factory)(std::string((const char*)NULL, 0)));
		c->open();
		char* dummy = NULL;
		cut_assert_equal_int(-1, c->readsize(1, &dummy));
		cut_assert_null(dummy);
	}

	void readline_basic(connection_factory factory)
	{
		shared_connection c((*factory)("1st line\r\n2nd line\r\n"));
		c->open();
		char* buffer;
		cut_assert_equal_int(9, c->readline(&buffer));
		cut_assert_equal_string("1st line\n", buffer);
		delete[] buffer;
	}

	void readline_unix(connection_factory factory)
	{
		shared_connection c((*factory)("1st line\n2nd line\n"));
		c->open();
		char* buffer;
		cut_assert_equal_int(9, c->readline(&buffer));
		cut_assert_equal_string("1st line\n", buffer);
		delete[] buffer;
	}

	void push_back_basic(connection_factory factory)
	{
		shared_connection c((*factory)("Ugly Bob\r\n"));
		c->open();
		char* buffer;
		cut_assert_equal_int(2, c->readsize(2, &buffer));
		cut_assert_equal_substring("Ug", buffer, 2);
		delete[] buffer;
		cut_assert_equal_int(2, c->readsize(2, &buffer));
		cut_assert_equal_substring("ly", buffer, 2);
		delete[] buffer;
		std::string ugly = "Ugly";
		c->push_back(ugly.c_str(), ugly.size());
		cut_assert_equal_int(9, c->readline(&buffer));
		cut_assert_equal_string("Ugly Bob\n", buffer);
		delete[] buffer;
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
