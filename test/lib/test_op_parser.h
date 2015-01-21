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
 *	test_op_parser.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <op_parser_binary.h>
#include <op_parser_text.h>

using namespace gree::flare;

namespace test_op_parser
{

class op_parser_binary_test : public op_parser_binary
{
public:
	op_parser_binary_test(shared_connection c)
		: op_parser_binary(c) { }
	virtual ~op_parser_binary_test() { }

protected:
	op* _determine_op(const binary_request_header&) { return NULL; }
};

class op_parser_text_test : public op_parser_text
{
public:
	op_parser_text_test(shared_connection c)
		: op_parser_text(c) { }
	virtual ~op_parser_text_test() { }

protected:
	op* _determine_op(const char* first, const char* buf, int& consume);
};

}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
