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
 *	test_op_repl_sync_wal.cc
 *
 *	wire-protocol parser tests for repl_sync_wal (server side)
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_repl_sync_wal.h>

using namespace gree::flare;

namespace test_op_repl_sync_wal
{
	// op_repl_sync_wal's ctor is (shared_connection, storage*). The
	// server-side parser never dereferences the storage pointer, so the
	// tests below construct the op with a NULL storage — mirroring how
	// op_get/op_dump tests pass NULL for their cluster/storage args.
	TEST_OP_CLASS_BEGIN(op_repl_sync_wal, NULL)
		EXPOSE(op_repl_sync_wal, _lsn);
		EXPOSE(op_repl_sync_wal, _client_master_id);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	// valid: "repl_sync_wal 100 abc-uuid" -> lsn=100, master_id=abc-uuid
	void test_parse_text_server_parameters_lsn_and_master_id()
	{
		shared_connection c(new connection_sstream(" 100 abc-uuid\r\n"));
		test_op_repl_sync_wal op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cppcut_assert_equal(static_cast<uint64_t>(100), op._lsn);
		cut_assert_equal_string("abc-uuid", op._client_master_id.c_str());
	}

	// valid: lsn only, master_id "-" means "no prior lineage" -> empty id
	void test_parse_text_server_parameters_no_lineage()
	{
		shared_connection c(new connection_sstream(" 42 -\r\n"));
		test_op_repl_sync_wal op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cppcut_assert_equal(static_cast<uint64_t>(42), op._lsn);
		cut_assert_equal_string("", op._client_master_id.c_str());
	}

	// valid: lsn only, no master_id token at all (pre-token client) -> empty id
	void test_parse_text_server_parameters_lsn_only()
	{
		shared_connection c(new connection_sstream(" 7\r\n"));
		test_op_repl_sync_wal op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cppcut_assert_equal(static_cast<uint64_t>(7), op._lsn);
		cut_assert_equal_string("", op._client_master_id.c_str());
	}

	// malformed: non-numeric LSN -> parse error, no crash
	void test_parse_text_server_parameters_non_numeric_lsn()
	{
		shared_connection c(new connection_sstream(" notanumber abc-uuid\r\n"));
		test_op_repl_sync_wal op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	// malformed: empty line -> parse error, no crash
	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_repl_sync_wal op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	// malformed: no LSN, only whitespace/newline -> parse error
	void test_parse_text_server_parameters_blank_line()
	{
		shared_connection c(new connection_sstream(" \r\n"));
		test_op_repl_sync_wal op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	// extra parameters beyond master_id are ignored ("bogus parameter")
	void test_parse_text_server_parameters_extra_ignored()
	{
		shared_connection c(new connection_sstream(" 100 abc-uuid extra junk\r\n"));
		test_op_repl_sync_wal op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cppcut_assert_equal(static_cast<uint64_t>(100), op._lsn);
		cut_assert_equal_string("abc-uuid", op._client_master_id.c_str());
	}

	// huge LSN (uint64 max) parses without overflow
	void test_parse_text_server_parameters_huge_lsn()
	{
		shared_connection c(new connection_sstream(" 18446744073709551615 abc-uuid\r\n"));
		test_op_repl_sync_wal op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cppcut_assert_equal(static_cast<uint64_t>(18446744073709551615ULL), op._lsn);
		cut_assert_equal_string("abc-uuid", op._client_master_id.c_str());
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
