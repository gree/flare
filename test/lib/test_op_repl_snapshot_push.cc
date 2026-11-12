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
 *	test_op_repl_snapshot_push.cc
 *
 *	destination side of repl_snapshot_push: the per-key-only switch
 *	(`cluster-replication-snapshot-push = false`) refuses an incoming push
 *	before anything else (user decision 2026-10-13, item 1)
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_repl_snapshot_push.h>

using namespace gree::flare;

namespace test_op_repl_snapshot_push
{
	// cluster and storage are NULL: the refusal must come before any use of
	// them (with the switch on, the same op answers not_rocksdb / no_cluster
	// — it got past the switch)
	TEST_OP_CLASS_BEGIN(op_repl_snapshot_push, NULL, NULL)
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		op_repl_snapshot_push::accept_push = true;
	}

	void teardown()
	{
		op_repl_snapshot_push::accept_push = true;
		delete stats_object;
		stats_object = NULL;
	}

	void test_switch_off_refuses_an_incoming_push_before_anything_else()
	{
		op_repl_snapshot_push::accept_push = false;
		shared_connection c(new connection_sstream(""));
		test_op_repl_snapshot_push op(c);
		op._run_server();
		std::string out = static_cast<connection_sstream*>(c.get())->get_output();
		cut_assert_true(out.find("snapshot_push_disabled") != std::string::npos,
			cut_message("with the switch off the push must be refused as snapshot_push_disabled; got [%s]", out.c_str()));
		cut_assert_true(out.find("SERVER_ERROR") == 0, cut_message("got [%s]", out.c_str()));
	}

	void test_switch_on_does_not_refuse_by_the_switch()
	{
		op_repl_snapshot_push::accept_push = true;
		shared_connection c(new connection_sstream(""));
		test_op_repl_snapshot_push op(c);
		op._run_server();
		std::string out = static_cast<connection_sstream*>(c.get())->get_output();
		cut_assert_true(out.find("snapshot_push_disabled") == std::string::npos,
			cut_message("the switch is on: [%s]", out.c_str()));
		cut_assert_true(out.find("SERVER_ERROR") == 0, cut_message("NULL storage/cluster answer an error: [%s]", out.c_str()));
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
