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
 *	test_op_parser.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op_parser.h"
#include "connection_iostream.h"

#include <op_parser.h>
#include <op_version.h>

using namespace gree::flare;

namespace test_op_parser
{
	op* op_parser_text_test::_determine_op(const char* first, const char* buf, int& consume)
	{
		op* r = NULL;
		if (strcmp(first, "version") == 0) {
			r = static_cast<op*>(new op_version(this->_connection)); 
		}
		return r;
	}

	void setup()
	{ }

	op* parse_text(const std::string& text)
	{
		shared_connection c(new connection_sstream(text));
		return op_parser::parse_server<op_parser_binary_test,
					 op_parser_text_test>(c);
	}

	void test_parse_empty_string()
	{
		op* r = parse_text(std::string());
		cut_assert_null(r);
	}

	void test_parse_text_version()
	{
		op* r = parse_text("version\r\n");
		cut_assert_not_null(r);
		if (r) {
			cut_assert_equal_string(r->get_ident().c_str(), "version");
		}
		delete r;
	}

	void teardown()
	{ }
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
