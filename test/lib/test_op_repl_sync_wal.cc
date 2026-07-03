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
 *	Wire-protocol tests for the WAL push replication op. These drive
 *	both protocol sides through a scripted connection so that framing,
 *	error classification, and malformed input never reach production
 *	untested.
 */

#include <cppcutter.h>

#include "connection_iostream.h"
#include "mock_cluster.h"

#include <app.h>
#include <op_repl_sync_wal.h>
#include <storage_rocksdb.h>

#include <sys/stat.h>
#include <sys/types.h>

using namespace std;
using namespace gree::flare;

namespace test_op_repl_sync_wal
{
	const char source_dir[] = "tmp_rocksdb_op_wal_source";
	const char dest_dir[]   = "tmp_rocksdb_op_wal_dest";

	struct test_op : public op_repl_sync_wal {
		test_op(shared_connection c, storage* st, cluster* cl): op_repl_sync_wal(c, st, cl) { }
		using op_repl_sync_wal::_parse_text_server_parameters;
		using op_repl_sync_wal::_run_server;
	};

	// A destination cluster that is WAL-sync eligible: exactly one
	// active partition (0) with no slave. Kept as a single shared
	// instance per test via make/drop.
	mock_cluster* make_safe_cluster() {
		mock_cluster* cl = new mock_cluster("dest", 12121);
		cluster::node master = cl->set_node("dest", 12121, cluster::role_master, cluster::state_active, 0);
		cl->set_partition(0, master);
		return cl;
	}

	// A destination cluster that is NOT WAL-sync eligible: two
	// partitions, so applying WAL locally would misroute keys.
	mock_cluster* make_unsafe_cluster() {
		mock_cluster* cl = new mock_cluster("dest", 12121);
		cluster::node m0 = cl->set_node("dest",  12121, cluster::role_master, cluster::state_active, 0);
		cluster::node m1 = cl->set_node("dest2", 12122, cluster::role_master, cluster::state_active, 1);
		cl->set_partition(0, m0);
		cl->set_partition(1, m1);
		return cl;
	}

	storage_rocksdb* make_rocksdb(const char* dir) {
		mkdir(dir, 0700);
		storage_rocksdb* s = new storage_rocksdb(
			dir,
			32,     // mutex_slot_size
			4,      // header_cache_size
			16,     // block_cache_size_mb
			4,      // write_buffer_size_mb
			2,      // max_write_buffer_number
			86400,  // wal_ttl_seconds
			1024);  // wal_size_limit_mb
		s->open();
		return s;
	}

	void drop_rocksdb(storage_rocksdb*& s, const char* dir) {
		if (s) {
			s->close();
			delete s;
			s = NULL;
		}
		cut_remove_path(dir, NULL);
	}

	int storage_set_string(storage* s, const string& key, const string& value) {
		storage::entry e;
		e.key = key;
		e.flag = 0;
		e.expire = 0;
		e.version = 0;
		e.size = value.size();
		shared_byte data(new uint8_t[value.size()]);
		memcpy(data.get(), value.data(), value.size());
		e.data = data;
		storage::result r;
		return s->set(e, r, 0);
	}

	int storage_get_string(storage* s, const string& key, string& out) {
		storage::entry e;
		e.key = key;
		storage::result r;
		int rc = s->get(e, r, 0);
		if (rc < 0 || r == storage::result_not_found) {
			return -1;
		}
		out.assign(reinterpret_cast<const char*>(e.data.get()), e.size);
		return 0;
	}

	// Frame every WAL batch after from_lsn the way _stream_batches()
	// does: "LSN <end_seq>\r\nBATCH <size>\r\n<raw>\r\n".
	string frame_updates(storage_rocksdb* src, uint64_t from_lsn, uint64_t& last_end_seq) {
		vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
		cut_assert_equal_int(0, src->get_updates_since(from_lsn, updates));
		string framed;
		last_end_seq = from_lsn;
		for (size_t i = 0; i < updates.size(); i++) {
			int op_count = updates[i].second.Count();
			uint64_t end_seq = updates[i].first + (op_count > 0 ? op_count - 1 : 0);
			if (end_seq <= from_lsn) {
				continue;
			}
			string data = updates[i].second.Data();
			char buf[64];
			snprintf(buf, sizeof(buf), "LSN %llu\r\nBATCH %zu\r\n",
				(unsigned long long)end_seq, data.size());
			framed += buf;
			framed += data;
			framed += "\r\n";
			last_end_seq = end_seq;
		}
		return framed;
	}

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	// --- server-side request parsing ---------------------------------

	void test_parse_server_begin()
	{
		shared_connection c(new connection_sstream(" begin some-master-id\r\n"));
		test_op op(c, NULL, NULL);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
	}

	void test_parse_server_seed()
	{
		shared_connection c(new connection_sstream(" seed some-master-id 42\r\n"));
		test_op op(c, NULL, NULL);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
	}

	void test_parse_server_unknown_subcommand()
	{
		shared_connection c(new connection_sstream(" 12345 some-source-id\r\n"));
		test_op op(c, NULL, NULL);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_server_seed_missing_lsn()
	{
		shared_connection c(new connection_sstream(" seed some-source-id\r\n"));
		test_op op(c, NULL, NULL);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	void test_parse_server_seed_bogus_lsn()
	{
		// must fail cleanly, not throw bad_lexical_cast up the stack
		shared_connection c(new connection_sstream(" seed some-source-id 99999999999999999999999999\r\n"));
		test_op op(c, NULL, NULL);
		cut_assert_equal_int(-1, op._parse_text_server_parameters());
	}

	// --- destination (server) side ------------------------------------

	// A source id that does not match what the dest was seeded by is
	// refused (dest echoes its own recorded source id).
	void test_server_begin_source_mismatch()
	{
		storage_rocksdb* dest = make_rocksdb(dest_dir);
		mock_cluster* cl = make_safe_cluster();
		// dest currently follows some other source
		cut_assert_equal_int(0, dest->set_repl_source("the-real-source", 5));

		shared_connection c(new connection_sstream(" begin somebody-else\r\n"));
		test_op op(c, dest, cl);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		op._run_server();

		connection_sstream* cs = dynamic_cast<connection_sstream*>(c.get());
		string out = cs->get_output();
		cut_assert_true(out.find("SERVER_ERROR master_id_mismatch the-real-source") != string::npos);
		cut_assert_equal_int(1, (int)dest->get_wal_sync_master_id_mismatch());

		delete cl;
		drop_rocksdb(dest, dest_dir);
	}

	// A destination in an ineligible topology refuses WAL sync entirely.
	void test_server_begin_topology_unsupported()
	{
		storage_rocksdb* dest = make_rocksdb(dest_dir);
		mock_cluster* cl = make_unsafe_cluster();
		cut_assert_equal_int(0, dest->set_repl_source("src-id", 0));

		shared_connection c(new connection_sstream(" begin src-id\r\n"));
		test_op op(c, dest, cl);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		op._run_server();

		connection_sstream* cs = dynamic_cast<connection_sstream*>(c.get());
		cut_assert_true(cs->get_output().find("SERVER_ERROR topology_unsupported") != string::npos);

		delete cl;
		drop_rocksdb(dest, dest_dir);
	}

	void test_server_seed_records_source_and_lsn()
	{
		storage_rocksdb* dest = make_rocksdb(dest_dir);
		mock_cluster* cl = make_safe_cluster();
		// dest's own master_id must be unaffected by the seed
		string own_id = dest->get_master_id();

		shared_connection c(new connection_sstream(" seed upstream-source-id 1234\r\n"));
		test_op op(c, dest, cl);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		op._run_server();

		connection_sstream* cs = dynamic_cast<connection_sstream*>(c.get());
		cut_assert_true(cs->get_output().find("OK") == 0);
		cut_assert_equal_string("upstream-source-id", dest->get_repl_source_id().c_str());
		cut_assert_equal_int(1234, (int)dest->get_repl_last_lsn());
		cut_assert_equal_string(own_id.c_str(), dest->get_master_id().c_str());

		delete cl;
		drop_rocksdb(dest, dest_dir);
	}

	void test_server_begin_receives_and_applies_batches()
	{
		storage_rocksdb* src  = make_rocksdb(source_dir);
		storage_rocksdb* dest = make_rocksdb(dest_dir);
		mock_cluster* cl = make_safe_cluster();

		// dest already follows src's source (as after a full dump + seed)
		cut_assert_equal_int(0, dest->set_repl_source(src->get_master_id(), 0));
		string dest_own_id = dest->get_master_id();

		cut_assert_equal_int(0, storage_set_string(src, "wal_key_a", "alpha"));
		cut_assert_equal_int(0, storage_set_string(src, "wal_key_b", "bravo"));

		uint64_t last_end_seq = 0;
		string framed = frame_updates(src, 0, last_end_seq);
		cut_assert_true(!framed.empty());

		string input = " begin " + src->get_master_id() + "\r\n" + framed + "END\r\n";
		shared_connection c(new connection_sstream(input));
		test_op op(c, dest, cl);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_operator(op._run_server(), >=, 0);

		connection_sstream* cs = dynamic_cast<connection_sstream*>(c.get());
		string out = cs->get_output();
		// dest reported its position first, then acknowledged the stream
		cut_assert_true(out.find("LSN 0\r\n") == 0);
		char ok_line[64];
		snprintf(ok_line, sizeof(ok_line), "OK %llu", (unsigned long long)last_end_seq);
		cut_assert_true(out.find(ok_line) != string::npos);

		// the replicated data is visible through the normal read path and
		// the recorded position advanced
		string value;
		cut_assert_equal_int(0, storage_get_string(dest, "wal_key_a", value));
		cut_assert_equal_string("alpha", value.c_str());
		cut_assert_equal_int(0, storage_get_string(dest, "wal_key_b", value));
		cut_assert_equal_string("bravo", value.c_str());
		cut_assert_equal_int((int)last_end_seq, (int)dest->get_repl_last_lsn());
		// the source's own metadata markers were filtered: dest keeps its
		// own master_id and the recorded source is unchanged
		cut_assert_equal_string(dest_own_id.c_str(), dest->get_master_id().c_str());
		cut_assert_equal_string(src->get_master_id().c_str(), dest->get_repl_source_id().c_str());

		delete cl;
		drop_rocksdb(src, source_dir);
		drop_rocksdb(dest, dest_dir);
	}

	void test_server_begin_abort_keeps_connection_synchronized()
	{
		storage_rocksdb* src  = make_rocksdb(source_dir);
		storage_rocksdb* dest = make_rocksdb(dest_dir);
		mock_cluster* cl = make_safe_cluster();
		cut_assert_equal_int(0, dest->set_repl_source(src->get_master_id(), 0));

		string input = " begin " + src->get_master_id() + "\r\nABORT lsn_purged\r\n";
		shared_connection c(new connection_sstream(input));
		test_op op(c, dest, cl);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_operator(op._run_server(), >=, 0);

		connection_sstream* cs = dynamic_cast<connection_sstream*>(c.get());
		// one LSN line + one acknowledgment: the source can keep using
		// the connection for the full-dump fallback
		cut_assert_true(cs->get_output().find("OK aborted") != string::npos);

		delete cl;
		drop_rocksdb(src, source_dir);
		drop_rocksdb(dest, dest_dir);
	}

	void test_server_begin_malformed_batch_size_fails_cleanly()
	{
		storage_rocksdb* src  = make_rocksdb(source_dir);
		storage_rocksdb* dest = make_rocksdb(dest_dir);
		mock_cluster* cl = make_safe_cluster();
		cut_assert_equal_int(0, dest->set_repl_source(src->get_master_id(), 0));

		string input = " begin " + src->get_master_id() + "\r\nLSN 5\r\nBATCH not_a_number\r\n";
		shared_connection c(new connection_sstream(input));
		test_op op(c, dest, cl);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		// unrecoverable framing error -> -1, but no crash and nothing applied
		cut_assert_equal_int(-1, op._run_server());
		cut_assert_equal_int(0, (int)dest->get_repl_last_lsn());

		delete cl;
		drop_rocksdb(src, source_dir);
		drop_rocksdb(dest, dest_dir);
	}

	void test_server_begin_oversized_batch_rejected()
	{
		storage_rocksdb* src  = make_rocksdb(source_dir);
		storage_rocksdb* dest = make_rocksdb(dest_dir);
		mock_cluster* cl = make_safe_cluster();
		cut_assert_equal_int(0, dest->set_repl_source(src->get_master_id(), 0));
		dest->set_wal_max_batch_bytes(8);	// tiny receive ceiling

		cut_assert_equal_int(0, storage_set_string(src, "wal_big", "0123456789abcdef"));
		uint64_t last_end_seq = 0;
		string framed = frame_updates(src, 0, last_end_seq);

		string input = " begin " + src->get_master_id() + "\r\n" + framed + "END\r\n";
		shared_connection c(new connection_sstream(input));
		test_op op(c, dest, cl);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		cut_assert_operator(op._run_server(), >=, 0);

		connection_sstream* cs = dynamic_cast<connection_sstream*>(c.get());
		// declined, stream drained, connection still synchronized
		cut_assert_true(cs->get_output().find("SERVER_ERROR batch_too_large") != string::npos);
		string value;
		cut_assert_equal_int(-1, storage_get_string(dest, "wal_big", value));

		delete cl;
		drop_rocksdb(src, source_dir);
		drop_rocksdb(dest, dest_dir);
	}

	// --- source (client) side ------------------------------------------

	void test_client_push_streams_delta_and_succeeds()
	{
		storage_rocksdb* src = make_rocksdb(source_dir);
		cut_assert_equal_int(0, storage_set_string(src, "push_key", "push_value"));
		uint64_t latest = src->get_latest_sequence_number();

		// scripted destination: follows our lineage from LSN 0, then
		// acknowledges the stream
		char response[64];
		snprintf(response, sizeof(response), "LSN 0\r\nOK %llu\r\n", (unsigned long long)latest);
		shared_connection c(new connection_sstream(string(response)));
		op_repl_sync_wal op(c, src, NULL);
		cut_assert_equal_int(0, op.run_client_push(src->get_master_id()));
		cut_assert_equal_int(op_repl_sync_wal::client_success, op.get_client_result());
		cut_assert_true(!op.connection_dirty());

		connection_sstream* cs = dynamic_cast<connection_sstream*>(c.get());
		string out = cs->get_output();
		cut_assert_true(out.find("repl_sync_wal begin " + src->get_master_id() + "\r\n") == 0);
		cut_assert_true(out.find("BATCH ") != string::npos);
		cut_assert_true(out.find("END\r\n") != string::npos);

		drop_rocksdb(src, source_dir);
	}

	void test_client_push_classifies_master_id_mismatch()
	{
		storage_rocksdb* src = make_rocksdb(source_dir);

		shared_connection c(new connection_sstream("SERVER_ERROR master_id_mismatch other-lineage\r\n"));
		op_repl_sync_wal op(c, src, NULL);
		cut_assert_equal_int(-1, op.run_client_push(src->get_master_id()));
		cut_assert_equal_int(op_repl_sync_wal::client_master_id_mismatch, op.get_client_result());
		cut_assert_equal_string("other-lineage", op.get_server_source_id().c_str());
		cut_assert_true(!op.connection_dirty());	// safe to reuse for full dump

		drop_rocksdb(src, source_dir);
	}

	void test_client_push_classifies_not_supported_on_error_reply()
	{
		storage_rocksdb* src = make_rocksdb(source_dir);

		// old flared replies a single ERROR line to unknown ops
		shared_connection c(new connection_sstream("ERROR\r\n"));
		op_repl_sync_wal op(c, src, NULL);
		cut_assert_equal_int(-1, op.run_client_push(src->get_master_id()));
		cut_assert_equal_int(op_repl_sync_wal::client_not_supported, op.get_client_result());
		cut_assert_true(!op.connection_dirty());

		drop_rocksdb(src, source_dir);
	}

	void test_client_push_aborts_when_dest_ahead()
	{
		storage_rocksdb* src = make_rocksdb(source_dir);

		// destination claims a position far beyond our WAL: the client
		// must abort the stream (keeping both sides synchronized) and
		// classify the failure for the full-dump fallback
		shared_connection c(new connection_sstream("LSN 99999999\r\nOK aborted\r\n"));
		op_repl_sync_wal op(c, src, NULL);
		cut_assert_equal_int(-1, op.run_client_push(src->get_master_id()));
		cut_assert_equal_int(op_repl_sync_wal::client_lsn_ahead, op.get_client_result());
		cut_assert_true(!op.connection_dirty());

		connection_sstream* cs = dynamic_cast<connection_sstream*>(c.get());
		cut_assert_true(cs->get_output().find("ABORT lsn_ahead\r\n") != string::npos);

		drop_rocksdb(src, source_dir);
	}

	void test_client_push_malformed_lsn_marks_connection_dirty_free()
	{
		storage_rocksdb* src = make_rocksdb(source_dir);

		// non-numeric LSN reply: the client aborts the stream instead of
		// crashing on bad_lexical_cast
		shared_connection c(new connection_sstream("LSN abc\r\nOK aborted\r\n"));
		op_repl_sync_wal op(c, src, NULL);
		cut_assert_equal_int(-1, op.run_client_push(src->get_master_id()));
		cut_assert_equal_int(op_repl_sync_wal::client_protocol_error, op.get_client_result());

		drop_rocksdb(src, source_dir);
	}

	void test_client_push_garbage_reply_is_dirty()
	{
		storage_rocksdb* src = make_rocksdb(source_dir);

		shared_connection c(new connection_sstream("GARBAGE RESPONSE\r\n"));
		op_repl_sync_wal op(c, src, NULL);
		cut_assert_equal_int(-1, op.run_client_push(src->get_master_id()));
		cut_assert_equal_int(op_repl_sync_wal::client_protocol_error, op.get_client_result());
		cut_assert_true(op.connection_dirty());	// caller must reconnect

		drop_rocksdb(src, source_dir);
	}

	void test_client_seed_success_and_refusal()
	{
		storage_rocksdb* src = make_rocksdb(source_dir);

		{
			shared_connection c(new connection_sstream("OK\r\n"));
			op_repl_sync_wal op(c, src, NULL);
			cut_assert_equal_int(0, op.run_client_seed(src->get_master_id(), 77));
			connection_sstream* cs = dynamic_cast<connection_sstream*>(c.get());
			string expected = "repl_sync_wal seed " + src->get_master_id() + " 77\r\n";
			cut_assert_equal_string(expected.c_str(), cs->get_output().c_str());
		}
		{
			shared_connection c(new connection_sstream("SERVER_ERROR seed_failed\r\n"));
			op_repl_sync_wal op(c, src, NULL);
			cut_assert_equal_int(-1, op.run_client_seed(src->get_master_id(), 77));
			cut_assert_true(!op.connection_dirty());
		}

		drop_rocksdb(src, source_dir);
	}

	// --- end-to-end: client output is valid server input ----------------

	void test_push_stream_roundtrip()
	{
		storage_rocksdb* src  = make_rocksdb(source_dir);
		storage_rocksdb* dest = make_rocksdb(dest_dir);
		mock_cluster* cl = make_safe_cluster();
		cut_assert_equal_int(0, dest->set_repl_source(src->get_master_id(), 0));

		cut_assert_equal_int(0, storage_set_string(src, "rt_key", "roundtrip"));
		uint64_t latest = src->get_latest_sequence_number();

		// 1) client run against a scripted destination
		char response[64];
		snprintf(response, sizeof(response), "LSN 0\r\nOK %llu\r\n", (unsigned long long)latest);
		shared_connection cc(new connection_sstream(string(response)));
		op_repl_sync_wal client_op(cc, src, NULL);
		cut_assert_equal_int(0, client_op.run_client_push(src->get_master_id()));
		string client_out = dynamic_cast<connection_sstream*>(cc.get())->get_output();

		// 2) feed the client's byte stream to a real destination server
		// (strip the leading op name that the parser dispatch consumes)
		const string op_name = "repl_sync_wal";
		cut_assert_true(client_out.compare(0, op_name.size(), op_name) == 0);
		string server_input = client_out.substr(op_name.size());
		shared_connection sc(new connection_sstream(server_input));
		test_op server_op(sc, dest, cl);
		cut_assert_equal_int(0, server_op._parse_text_server_parameters());
		cut_assert_operator(server_op._run_server(), >=, 0);

		string value;
		cut_assert_equal_int(0, storage_get_string(dest, "rt_key", value));
		cut_assert_equal_string("roundtrip", value.c_str());
		cut_assert_equal_int((int)latest, (int)dest->get_repl_last_lsn());

		delete cl;
		drop_rocksdb(src, source_dir);
		drop_rocksdb(dest, dest_dir);
	}

	void teardown()
	{
		cut_remove_path(source_dir, NULL);
		cut_remove_path(dest_dir, NULL);
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
