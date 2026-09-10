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
 *	test_op_meta.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_meta.h>

using namespace gree::flare;

namespace test_op_meta
{
	TEST_OP_CLASS_BEGIN(op_meta, NULL)
		EXPOSE(op_meta, _parse_text_client_features);
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void test_parse_text_server_parameters_empty()
	{
		shared_connection c(new connection_sstream(std::string()));
		test_op_meta op(c);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
	}

	void test_parse_text_server_parameters_garbage()
	{
		shared_connection c(new connection_sstream(" garbage\r\n"));
		test_op_meta op(c);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	// Full modern reply: all three fields present and parsed.
	void test_parse_features_full()
	{
		shared_connection c(new connection_sstream("OK rocksdb_wal=1 master_id=abc-uuid latest_lsn=1000\r\n"));
		test_op_meta op(c);
		bool wal = false;
		std::string master_id;
		uint64_t lsn = 0;
		cut_assert_equal_int(0, op._parse_text_client_features(wal, master_id, lsn));
		cut_assert_equal_int(1, wal ? 1 : 0);
		cut_assert_equal_string("abc-uuid", master_id.c_str());
		cppcut_assert_equal(static_cast<uint64_t>(1000), lsn);
	}

	// Older server that predates latest_lsn: absent token -> lsn defaults to 0.
	void test_parse_features_no_latest_lsn()
	{
		shared_connection c(new connection_sstream("OK rocksdb_wal=1 master_id=abc-uuid\r\n"));
		test_op_meta op(c);
		bool wal = false;
		std::string master_id;
		uint64_t lsn = 12345;  // must be reset to 0 by the parser
		cut_assert_equal_int(0, op._parse_text_client_features(wal, master_id, lsn));
		cut_assert_equal_int(1, wal ? 1 : 0);
		cut_assert_equal_string("abc-uuid", master_id.c_str());
		cppcut_assert_equal(static_cast<uint64_t>(0), lsn);
	}

	// Unknown/extra tokens are ignored; known tokens still parse in any order.
	void test_parse_features_ignores_unknown_tokens()
	{
		shared_connection c(new connection_sstream("OK future_feature=xyz rocksdb_wal=1 latest_lsn=7 master_id=id2 another=1\r\n"));
		test_op_meta op(c);
		bool wal = false;
		std::string master_id;
		uint64_t lsn = 0;
		cut_assert_equal_int(0, op._parse_text_client_features(wal, master_id, lsn));
		cut_assert_equal_int(1, wal ? 1 : 0);
		cut_assert_equal_string("id2", master_id.c_str());
		cppcut_assert_equal(static_cast<uint64_t>(7), lsn);
	}

	// A non-parseable latest_lsn value is ignored (stays 0), not a crash/error.
	void test_parse_features_bad_latest_lsn_ignored()
	{
		shared_connection c(new connection_sstream("OK rocksdb_wal=1 latest_lsn=notanumber\r\n"));
		test_op_meta op(c);
		bool wal = false;
		std::string master_id;
		uint64_t lsn = 999;
		cut_assert_equal_int(0, op._parse_text_client_features(wal, master_id, lsn));
		cut_assert_equal_int(1, wal ? 1 : 0);
		cppcut_assert_equal(static_cast<uint64_t>(0), lsn);
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
