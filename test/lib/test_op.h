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
 *	test_op.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#define EXPOSE(op, function) \
		using gree::flare::op::function;

#define TEST_OP_CLASS_BEGIN(op, ...) \
	struct test_##op : public gree::flare::op \
	{ \
		test_##op(gree::flare::shared_connection c) : op(c, ##__VA_ARGS__) { } \
		EXPOSE(op, _parse_text_server_parameters) \
		EXPOSE(op, _run_server) \
		EXPOSE(op, _run_client) \
		EXPOSE(op, _parse_text_client_parameters) \
		EXPOSE(op, _parse_binary_client_parameters) \
		EXPOSE(op, _parse_text_response) \
		EXPOSE(op, _result) \
		EXPOSE(op, _result_message)

#define TEST_OP_CLASS_END \
	};

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
