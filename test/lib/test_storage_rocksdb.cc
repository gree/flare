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
 *  test_storage_rocksdb.cc
 *
 *  Unit tests for RocksDB storage backend
 */
#include <cppcutter.h>

#include "common_storage_tests.h"
#include <app.h>
#include <storage_rocksdb.h>
#include <handler_wal_follower.h>
#include <op_repl_sync_wal.h>
#include "mock_storage.h"

#include <limits>
#include <sys/stat.h>
#include <sys/types.h>
#include <pthread.h>
#include <unistd.h>
#include <dirent.h>
#include <rocksdb/db.h>
#include <rocksdb/options.h>

using namespace std;

namespace test_storage_rocksdb
{
	const char tmp_dir[] = "tmp_rocksdb";
	test_storage::storage_tester* rocksdb_tester;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		const char *db_dir;
		db_dir = tmp_dir;
		mkdir(db_dir, 0700);
		rocksdb_tester = new test_storage::storage_tester(new storage_rocksdb(
					db_dir,
					32,        // mutex_slot_size
					4,         // header_cache_size
					512,       // block_cache_size_mb
					64,        // write_buffer_size_mb
					3,         // max_write_buffer_number
					86400,     // wal_ttl_seconds
					10240));   // wal_size_limit_mb
	}

// Common storage tests
COMMON_STORAGE_TEST(rocksdb_tester, get_not_found);
COMMON_STORAGE_TEST(rocksdb_tester, set_basic);
COMMON_STORAGE_TEST(rocksdb_tester, set_empty_key);
COMMON_STORAGE_TEST(rocksdb_tester, set_space_key);
COMMON_STORAGE_TEST(rocksdb_tester, set_multiline_key);
COMMON_STORAGE_TEST(rocksdb_tester, set_key_too_long_for_memcached);
COMMON_STORAGE_TEST(rocksdb_tester, set_enormous_value);
COMMON_STORAGE_TEST(rocksdb_tester, remove_not_found);
COMMON_STORAGE_TEST(rocksdb_tester, remove_basic);
COMMON_STORAGE_TEST(rocksdb_tester, multiple_iter_begin);
COMMON_STORAGE_TEST(rocksdb_tester, iter_basic);
COMMON_STORAGE_TEST(rocksdb_tester, iter_non_initialized);
COMMON_STORAGE_TEST(rocksdb_tester, iter_end_error);
COMMON_STORAGE_TEST(rocksdb_tester, iter_next_concurrent_add);
COMMON_STORAGE_TEST(rocksdb_tester, iter_next_concurrent_replace);
COMMON_STORAGE_TEST(rocksdb_tester, iter_next_concurrent_remove);
COMMON_STORAGE_TEST(rocksdb_tester, truncate);
COMMON_STORAGE_TEST(rocksdb_tester, count);

// Generate comprehensive test suites using macros
GENERATE_SET_TESTS(rocksdb_tester);
GENERATE_INCR_TESTS(rocksdb_tester);
GENERATE_REMOVE_TESTS(rocksdb_tester);
GENERATE_GET_TESTS(rocksdb_tester);

// ---------------------------------------------------------------------------
// WAL-based incremental replication tests
//
// These tests directly exercise the storage_rocksdb APIs used by
// op_repl_sync_wal (get_latest_sequence_number / get_updates_since /
// apply_batch_with_lsn / get_repl_last_lsn) to verify that incremental
// replication from a master instance to a slave instance produces an
// identical key/value state on the slave.
// ---------------------------------------------------------------------------

namespace {
	const char wal_master_dir[] = "tmp_rocksdb_wal_master";
	const char wal_slave_dir[]  = "tmp_rocksdb_wal_slave";

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

	// Close and delete the storage handle but LEAVE the directory on
	// disk so that the next make_rocksdb() / open() call on the same
	// path reopens the same database (used by reopen-persistence tests).
	void drop_rocksdb_noremove(storage_rocksdb*& s) {
		if (s) {
			s->close();
			delete s;
			s = NULL;
		}
	}

	int storage_set_string(storage* s, const string& key, const string& value) {
		storage::entry e;
		e.key = key;
		e.flag = 0;
		e.expire = 0;
		e.version = 0;     // let storage assign
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

	int storage_remove_key(storage* s, const string& key) {
		storage::entry e;
		e.key = key;
		e.version = 0;
		storage::result r;
		return s->remove(e, r, storage::behavior_skip_version);
	}

	// Replicate every update from master with lsn > from_lsn into slave.
	// Returns the number of batches applied, or -1 on error.
	int replicate_from(storage_rocksdb* master, storage_rocksdb* slave, uint64_t from_lsn) {
		vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
		int rc = master->get_updates_since(from_lsn, updates);
		if (rc < 0) {
			return rc;
		}
		int applied = 0;
		for (size_t i = 0; i < updates.size(); i++) {
			uint64_t seq = updates[i].first;
			// Skip batches the slave has already applied (inclusive semantics
			// of GetUpdatesSince means the first batch may be the one at
			// from_lsn itself).
			if (seq <= from_lsn) {
				continue;
			}
			if (slave->apply_batch_with_lsn(updates[i].second, seq) < 0) {
				return -1;
			}
			applied++;
		}
		return applied;
	}
}

void test_wal_get_latest_sequence_number_monotonic() {
	storage_rocksdb* m = make_rocksdb(wal_master_dir);

	uint64_t s0 = m->get_latest_sequence_number();
	cut_assert_equal_int(0, storage_set_string(m, "k1", "v1"));
	uint64_t s1 = m->get_latest_sequence_number();
	cut_assert_equal_int(0, storage_set_string(m, "k2", "v2"));
	uint64_t s2 = m->get_latest_sequence_number();

	cut_assert_operator(s1, >, s0);
	cut_assert_operator(s2, >, s1);

	drop_rocksdb(m, wal_master_dir);
}

void test_wal_get_updates_since_empty() {
	storage_rocksdb* m = make_rocksdb(wal_master_dir);

	vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
	uint64_t latest = m->get_latest_sequence_number();
	int rc = m->get_updates_since(latest, updates);

	cut_assert_equal_int(0, rc);
	// No updates after the latest sequence number.
	size_t new_count = 0;
	for (size_t i = 0; i < updates.size(); i++) {
		if (updates[i].first > latest) new_count++;
	}
	cut_assert_equal_int(0, static_cast<int>(new_count));

	drop_rocksdb(m, wal_master_dir);
}

void test_wal_incremental_replication_basic() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave  = make_rocksdb(wal_slave_dir);

	// Prepopulate master and slave to a common baseline using an initial
	// full "sync" (copy all current entries via WAL from sequence 0).
	cut_assert_equal_int(0, storage_set_string(master, "a", "alpha"));
	cut_assert_equal_int(0, storage_set_string(master, "b", "bravo"));
	cut_assert_operator(replicate_from(master, slave, 0), >=, 2);

	string out;
	cut_assert_equal_int(0, storage_get_string(slave, "a", out));
	cut_assert_equal_string("alpha", out.c_str());
	cut_assert_equal_int(0, storage_get_string(slave, "b", out));
	cut_assert_equal_string("bravo", out.c_str());

	// Record slave's current LSN, write more to master, then replicate
	// only the incremental delta.
	uint64_t slave_lsn = slave->get_repl_last_lsn();
	cut_assert_operator(slave_lsn, >, static_cast<uint64_t>(0));

	cut_assert_equal_int(0, storage_set_string(master, "c", "charlie"));
	cut_assert_equal_int(0, storage_set_string(master, "a", "alpha2"));  // update

	int applied = replicate_from(master, slave, slave_lsn);
	cut_assert_operator(applied, >=, 2);

	cut_assert_equal_int(0, storage_get_string(slave, "c", out));
	cut_assert_equal_string("charlie", out.c_str());
	cut_assert_equal_int(0, storage_get_string(slave, "a", out));
	cut_assert_equal_string("alpha2", out.c_str());

	drop_rocksdb(master, wal_master_dir);
	drop_rocksdb(slave,  wal_slave_dir);
}

void test_wal_incremental_replication_replays_deletes() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave  = make_rocksdb(wal_slave_dir);

	cut_assert_equal_int(0, storage_set_string(master, "keep", "1"));
	cut_assert_equal_int(0, storage_set_string(master, "drop", "2"));
	cut_assert_operator(replicate_from(master, slave, 0), >=, 2);

	// Sanity: slave has both keys.
	string out;
	cut_assert_equal_int(0, storage_get_string(slave, "drop", out));
	cut_assert_equal_string("2", out.c_str());

	uint64_t slave_lsn = slave->get_repl_last_lsn();

	// Delete on master, then replicate the delete.
	cut_assert_equal_int(0, storage_remove_key(master, "drop"));
	cut_assert_operator(replicate_from(master, slave, slave_lsn), >=, 1);

	cut_assert_equal_int(-1, storage_get_string(slave, "drop", out));
	cut_assert_equal_int(0,  storage_get_string(slave, "keep", out));
	cut_assert_equal_string("1", out.c_str());

	// O(1) curr_items bookkeeping must hold on BOTH roles: the master counts
	// through set()/remove(), the slave through the WriteBatch-apply handler
	// (replicated batches bypass set()/remove() entirely).
	cut_assert_equal_int(1, static_cast<int>(master->count()));
	cut_assert_equal_int(1, static_cast<int>(slave->count()));

	drop_rocksdb(master, wal_master_dir);
	drop_rocksdb(slave,  wal_slave_dir);
}

void test_wal_get_repl_last_lsn_tracks_applied_batches() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave  = make_rocksdb(wal_slave_dir);

	// Fresh slave has no previous sync.
	cut_assert_equal_int(0, static_cast<int>(slave->get_repl_last_lsn()));

	cut_assert_equal_int(0, storage_set_string(master, "x", "1"));
	cut_assert_equal_int(0, storage_set_string(master, "y", "2"));
	cut_assert_operator(replicate_from(master, slave, 0), >=, 2);

	uint64_t lsn_after_first = slave->get_repl_last_lsn();
	cut_assert_operator(lsn_after_first, >, static_cast<uint64_t>(0));

	// Another round -> LSN must advance.
	cut_assert_equal_int(0, storage_set_string(master, "z", "3"));
	cut_assert_operator(replicate_from(master, slave, lsn_after_first), >=, 1);

	uint64_t lsn_after_second = slave->get_repl_last_lsn();
	cut_assert_operator(lsn_after_second, >, lsn_after_first);

	drop_rocksdb(master, wal_master_dir);
	drop_rocksdb(slave,  wal_slave_dir);
}

// ---------------------------------------------------------------------------
// Phase A hardening tests
// ---------------------------------------------------------------------------

// Reserved metadata keys must be invisible to every user-facing operation.
void test_phaseA_reserved_keys_hidden_from_set_get_remove_iter() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	// set/get/remove on reserved keys are refused
	cut_assert_equal_int(0, storage_set_string(s, storage_rocksdb::kReplLastLsnKey, "evil"));
	string out;
	cut_assert_equal_int(-1, storage_get_string(s, storage_rocksdb::kReplLastLsnKey, out));
	cut_assert_equal_int(0, storage_remove_key(s, storage_rocksdb::kReplLastLsnKey));
	cut_assert_equal_int(0, storage_set_string(s, storage_rocksdb::kReplMasterIdKey, "evil"));
	cut_assert_equal_int(-1, storage_get_string(s, storage_rocksdb::kReplMasterIdKey, out));
	cut_assert_equal_int(0, storage_remove_key(s, storage_rocksdb::kReplMasterIdKey));

	// Populate some real data and verify iter_next never surfaces a reserved key
	cut_assert_equal_int(0, storage_set_string(s, "alpha", "1"));
	cut_assert_equal_int(0, storage_set_string(s, "bravo", "2"));

	cut_assert_equal_int(0, s->iter_begin());
	int seen_alpha = 0, seen_bravo = 0, seen_reserved = 0;
	storage::iteration it;
	string key;
	while ((it = s->iter_next(key)) == storage::iteration_continue) {
		if (key == "alpha") seen_alpha++;
		else if (key == "bravo") seen_bravo++;
		else if (storage_rocksdb::is_reserved_key(key)) seen_reserved++;
	}
	s->iter_end();
	cut_assert_equal_int(1, seen_alpha);
	cut_assert_equal_int(1, seen_bravo);
	cut_assert_equal_int(0, seen_reserved);

	// The master id still exists internally — accessible only via the
	// dedicated getter, never via storage operations.
	cut_assert_operator(s->get_master_id().empty(), ==, false);

	drop_rocksdb(s, wal_master_dir);
}

// count() must not include reserved metadata keys.
void test_phaseA_reserved_keys_excluded_from_count() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, storage_set_string(s, "k1", "v1"));
	cut_assert_equal_int(0, storage_set_string(s, "k2", "v2"));
	// The reserved master_id key has been written internally by open();
	// count() must still report only user keys.
	cut_assert_equal_int(2, static_cast<int>(s->count()));
	drop_rocksdb(s, wal_master_dir);
}

// truncate() must not destroy reserved metadata keys, so that lineage
// tracking survives flush_all.
void test_phaseA_truncate_preserves_master_id() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	string original_id = s->get_master_id();
	cut_assert_operator(original_id.empty(), ==, false);

	cut_assert_equal_int(0, storage_set_string(s, "k1", "v1"));
	cut_assert_equal_int(0, storage_set_string(s, "k2", "v2"));
	cut_assert_equal_int(0, s->truncate());

	// User data gone
	string out;
	cut_assert_equal_int(-1, storage_get_string(s, "k1", out));
	// Master id preserved
	cut_assert_equal_string(original_id.c_str(), s->get_master_id().c_str());

	drop_rocksdb(s, wal_master_dir);
}

// Master identity token persists across open/close cycles.
void test_phaseA_master_id_persists_across_reopen() {
	storage_rocksdb* s1 = make_rocksdb(wal_master_dir);
	string id1 = s1->get_master_id();
	cut_assert_operator(id1.empty(), ==, false);
	drop_rocksdb_noremove(s1);

	// Reopen WITHOUT removing the directory — expect the same id.
	storage_rocksdb* s2 = new storage_rocksdb(
		wal_master_dir, 32, 4, 16, 4, 2, 86400, 1024);
	cut_assert_equal_int(0, s2->open());
	cut_assert_equal_string(id1.c_str(), s2->get_master_id().c_str());
	s2->close();
	delete s2;
	cut_remove_path(wal_master_dir, NULL);
}

// Two independent DBs get distinct master ids.
void test_phaseA_master_id_unique_per_db() {
	storage_rocksdb* a = make_rocksdb(wal_master_dir);
	storage_rocksdb* b = make_rocksdb(wal_slave_dir);
	cut_assert_operator(a->get_master_id().empty(), ==, false);
	cut_assert_operator(b->get_master_id().empty(), ==, false);
	cut_assert_operator(a->get_master_id() != b->get_master_id(), ==, true);
	drop_rocksdb(a, wal_master_dir);
	drop_rocksdb(b, wal_slave_dir);
}

// set_master_id() overwrites and persists.
void test_phaseA_set_master_id_overwrites_and_persists() {
	storage_rocksdb* s1 = make_rocksdb(wal_master_dir);
	string new_id = "abcdef01-2345-6789-abcd-ef0123456789";
	cut_assert_equal_int(0, s1->set_master_id(new_id));
	cut_assert_equal_string(new_id.c_str(), s1->get_master_id().c_str());
	drop_rocksdb_noremove(s1);

	storage_rocksdb* s2 = new storage_rocksdb(
		wal_master_dir, 32, 4, 16, 4, 2, 86400, 1024);
	cut_assert_equal_int(0, s2->open());
	cut_assert_equal_string(new_id.c_str(), s2->get_master_id().c_str());
	s2->close();
	delete s2;
	cut_remove_path(wal_master_dir, NULL);
}

// ---------------------------------------------------------------------------
// Phase B hardening tests
// ---------------------------------------------------------------------------

// Resync failure streak increments and resets correctly.
void test_phaseB_resync_failure_count_tracking() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, static_cast<int>(s->get_resync_failure_count()));

	cut_assert_equal_int(1, static_cast<int>(s->notify_resync_result(false)));
	cut_assert_equal_int(2, static_cast<int>(s->notify_resync_result(false)));
	cut_assert_equal_int(3, static_cast<int>(s->notify_resync_result(false)));
	cut_assert_equal_int(3, static_cast<int>(s->get_resync_failure_count()));

	// Success resets the streak.
	cut_assert_equal_int(0, static_cast<int>(s->notify_resync_result(true)));
	cut_assert_equal_int(0, static_cast<int>(s->get_resync_failure_count()));

	// Another failure restarts from 1.
	cut_assert_equal_int(1, static_cast<int>(s->notify_resync_result(false)));

	drop_rocksdb(s, wal_master_dir);
}

// should_self_demote returns true only after the streak reaches the
// configured threshold; a threshold of 0 disables the feature entirely.
void test_phaseB_should_self_demote_respects_threshold() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	// Threshold 0 (default) -> never demote.
	cut_assert_equal_int(0, s->get_resync_failure_threshold());
	s->notify_resync_result(false);
	s->notify_resync_result(false);
	s->notify_resync_result(false);
	cut_assert_equal_int(0, s->should_self_demote() ? 1 : 0);

	s->notify_resync_result(true);  // reset

	// Threshold 3 -> demote when streak hits 3.
	s->set_resync_failure_threshold(3);
	cut_assert_equal_int(0, s->should_self_demote() ? 1 : 0);
	s->notify_resync_result(false);
	cut_assert_equal_int(0, s->should_self_demote() ? 1 : 0);
	s->notify_resync_result(false);
	cut_assert_equal_int(0, s->should_self_demote() ? 1 : 0);
	s->notify_resync_result(false);
	cut_assert_equal_int(1, s->should_self_demote() ? 1 : 0);

	// Success brings it back under threshold.
	s->notify_resync_result(true);
	cut_assert_equal_int(0, s->should_self_demote() ? 1 : 0);

	drop_rocksdb(s, wal_master_dir);
}

// WAL sync counters move as expected through a successful replication.
void test_phaseB_wal_counters_success_path() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave  = make_rocksdb(wal_slave_dir);

	uint64_t before = slave->get_wal_sync_success();

	cut_assert_equal_int(0, storage_set_string(master, "k", "v"));
	// Simulate a successful apply path by writing directly through
	// the storage API (bypassing the network layer which has the
	// documented direction-inversion caveat). The counter under test
	// is the "success" counter incremented at the end of the apply
	// sequence, which apply_batch_with_lsn does not touch — so we
	// call the increment helper directly as an op_repl_sync_wal
	// would after a successful loop.
	vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
	cut_assert_equal_int(0, master->get_updates_since(0, updates));
	cut_assert_operator(updates.empty(), ==, false);
	cut_assert_equal_int(0, slave->apply_batch_with_lsn(updates.back().second, 99));
	slave->incr_wal_sync_success();

	cut_assert_equal_int(static_cast<int>(before + 1),
		static_cast<int>(slave->get_wal_sync_success()));
	cut_assert_equal_int(99, static_cast<int>(slave->get_repl_last_lsn()));

	drop_rocksdb(master, wal_master_dir);
	drop_rocksdb(slave,  wal_slave_dir);
}

// Each mismatch/ahead/purged classification increments its own counter.
void test_phaseB_wal_counters_error_classifications() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	uint64_t m0 = s->get_wal_sync_master_id_mismatch();
	uint64_t a0 = s->get_wal_sync_lsn_ahead();
	uint64_t p0 = s->get_wal_sync_lsn_purged();
	uint64_t f0 = s->get_wal_sync_apply_failure();
	uint64_t o0 = s->get_wal_sync_other_error();
	uint64_t d0 = s->get_wal_fallback_to_dump();

	s->incr_wal_sync_master_id_mismatch();
	s->incr_wal_sync_lsn_ahead();
	s->incr_wal_sync_lsn_purged();
	s->incr_wal_sync_apply_failure();
	s->incr_wal_sync_other_error();
	s->incr_wal_fallback_to_dump();

	cut_assert_equal_int(static_cast<int>(m0 + 1), static_cast<int>(s->get_wal_sync_master_id_mismatch()));
	cut_assert_equal_int(static_cast<int>(a0 + 1), static_cast<int>(s->get_wal_sync_lsn_ahead()));
	cut_assert_equal_int(static_cast<int>(p0 + 1), static_cast<int>(s->get_wal_sync_lsn_purged()));
	cut_assert_equal_int(static_cast<int>(f0 + 1), static_cast<int>(s->get_wal_sync_apply_failure()));
	cut_assert_equal_int(static_cast<int>(o0 + 1), static_cast<int>(s->get_wal_sync_other_error()));
	cut_assert_equal_int(static_cast<int>(d0 + 1), static_cast<int>(s->get_wal_fallback_to_dump()));

	drop_rocksdb(s, wal_master_dir);
}

// ---------------------------------------------------------------------------
// Phase C tests (orphan scan / purge state machine at the storage level)
// ---------------------------------------------------------------------------

// A fresh scan produces a token with the recorded state.
void test_phaseC_orphan_scan_token_roundtrip() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	string t = s->remember_orphan_scan(42, 10, 2048);
	cut_assert_operator(t.empty(), ==, false);

	storage_rocksdb::orphan_scan_token out;
	cut_assert_equal_int(1, s->lookup_orphan_scan(t, out) ? 1 : 0);
	cut_assert_equal_string(t.c_str(), out.token.c_str());
	cut_assert_equal_int(42, static_cast<int>(out.node_map_version));
	cut_assert_equal_int(10, static_cast<int>(out.orphan_count));
	cut_assert_equal_int(2048, static_cast<int>(out.orphan_bytes));

	drop_rocksdb(s, wal_master_dir);
}

// Issuing a new scan invalidates the previous token.
void test_phaseC_orphan_scan_new_invalidates_old() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	string first = s->remember_orphan_scan(1, 1, 1);
	string second = s->remember_orphan_scan(2, 2, 2);
	cut_assert_operator(first != second, ==, true);

	storage_rocksdb::orphan_scan_token out;
	cut_assert_equal_int(0, s->lookup_orphan_scan(first, out) ? 1 : 0);
	cut_assert_equal_int(1, s->lookup_orphan_scan(second, out) ? 1 : 0);
	cut_assert_equal_int(2, static_cast<int>(out.node_map_version));

	drop_rocksdb(s, wal_master_dir);
}

// clear_orphan_scan() consumes the token so it cannot be replayed.
void test_phaseC_orphan_scan_clear_consumes_token() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	string t = s->remember_orphan_scan(7, 5, 500);
	storage_rocksdb::orphan_scan_token out;
	cut_assert_equal_int(1, s->lookup_orphan_scan(t, out) ? 1 : 0);
	s->clear_orphan_scan();
	cut_assert_equal_int(0, s->lookup_orphan_scan(t, out) ? 1 : 0);
	drop_rocksdb(s, wal_master_dir);
}

// A random unrelated token never validates.
void test_phaseC_orphan_scan_rejects_random_token() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	s->remember_orphan_scan(1, 1, 1);
	storage_rocksdb::orphan_scan_token out;
	cut_assert_equal_int(0, s->lookup_orphan_scan("not-a-real-token", out) ? 1 : 0);
	drop_rocksdb(s, wal_master_dir);
}

// ---------------------------------------------------------------------------
// Phase D tests (WAL streaming limits and throttling configuration)
// ---------------------------------------------------------------------------

// Default Phase D settings are "unlimited / inherit" so pre-Phase-D
// deployments see no change in behavior.
void test_phaseD_defaults_are_permissive() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, static_cast<int>(s->get_wal_max_batch_bytes()));
	cut_assert_equal_int(0, s->get_wal_sync_bwlimit());
	cut_assert_equal_int(0, s->get_wal_sync_interval());
	drop_rocksdb(s, wal_master_dir);
}

// Setters persist for the lifetime of the storage object and are
// independently observable via the getters.
void test_phaseD_setters_roundtrip() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	s->set_wal_max_batch_bytes(4 * 1024 * 1024);
	s->set_wal_sync_bwlimit(256);
	s->set_wal_sync_interval(1500);

	cut_assert_equal_int(static_cast<int>(4 * 1024 * 1024),
		static_cast<int>(s->get_wal_max_batch_bytes()));
	cut_assert_equal_int(256, s->get_wal_sync_bwlimit());
	cut_assert_equal_int(1500, s->get_wal_sync_interval());

	// Overwriting with 0 restores the "inherit / unlimited" semantics.
	s->set_wal_max_batch_bytes(0);
	s->set_wal_sync_bwlimit(0);
	s->set_wal_sync_interval(0);
	cut_assert_equal_int(0, static_cast<int>(s->get_wal_max_batch_bytes()));
	cut_assert_equal_int(0, s->get_wal_sync_bwlimit());
	cut_assert_equal_int(0, s->get_wal_sync_interval());

	drop_rocksdb(s, wal_master_dir);
}

// Tiny batch-size ceiling combined with a real write demonstrates the
// precondition for op_repl_sync_wal's batch_too_large check: a real
// batch does in fact exceed the configured ceiling. We verify from
// the storage side so that the check in op_repl_sync_wal is not a
// dead branch.
void test_phaseD_batch_size_ceiling_is_reachable() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	master->set_wal_max_batch_bytes(16);  // absurdly small

	string big_value(1024, 'x');
	cut_assert_equal_int(0, storage_set_string(master, "large_key", big_value));

	vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
	cut_assert_equal_int(0, master->get_updates_since(0, updates));
	cut_assert_operator(updates.empty(), ==, false);

	size_t max_seen = 0;
	for (size_t i = 0; i < updates.size(); i++) {
		size_t sz = updates[i].second.Data().size();
		if (sz > max_seen) max_seen = sz;
	}
	cut_assert_operator(max_seen, >, static_cast<size_t>(master->get_wal_max_batch_bytes()));

	drop_rocksdb(master, wal_master_dir);
}

// With a realistic ceiling, ordinary traffic never trips the guard.
void test_phaseD_batch_size_ceiling_does_not_false_positive() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	s->set_wal_max_batch_bytes(16 * 1024 * 1024);  // 16 MB

	cut_assert_equal_int(0, storage_set_string(s, "a", "A"));
	cut_assert_equal_int(0, storage_set_string(s, "b", "B"));
	cut_assert_equal_int(0, storage_set_string(s, "c", "C"));

	vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
	cut_assert_equal_int(0, s->get_updates_since(0, updates));
	for (size_t i = 0; i < updates.size(); i++) {
		cut_assert_operator(updates[i].second.Data().size(), <=,
			static_cast<size_t>(s->get_wal_max_batch_bytes()));
	}

	drop_rocksdb(s, wal_master_dir);
}

// apply_batch_with_lsn is atomic: after a successful call, both the
// key writes and the LSN marker are visible. After a failure (simulated
// here by applying a malformed batch), neither is visible.
void test_phaseA_apply_batch_with_lsn_atomic_success() {
	storage_rocksdb* master_s = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave_s  = make_rocksdb(wal_slave_dir);

	cut_assert_equal_int(0, storage_set_string(master_s, "a", "A"));
	cut_assert_equal_int(0, storage_set_string(master_s, "b", "B"));

	vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
	cut_assert_equal_int(0, master_s->get_updates_since(0, updates));
	cut_assert_operator(updates.empty(), ==, false);

	// Pick any non-trivial batch and apply with a synthetic LSN.
	uint64_t fake_lsn = 42;
	cut_assert_equal_int(0, slave_s->apply_batch_with_lsn(updates.back().second, fake_lsn));

	// LSN marker reflects the value we passed — proving it was updated
	// in the same Write() as the data, not skipped or lost.
	cut_assert_equal_int(static_cast<int>(fake_lsn),
		static_cast<int>(slave_s->get_repl_last_lsn()));

	drop_rocksdb(master_s, wal_master_dir);
	drop_rocksdb(slave_s,  wal_slave_dir);
}

// ---------------------------------------------------------------------------
// Concurrency: truncate() vs set()
//
// truncate() takes the wholelock in write mode plus every slot lock, so it
// must be mutually exclusive with set()/get()/remove() (which take the
// wholelock in read mode plus a single slot lock). This test hammers set()
// from a worker thread while the main thread interleaves truncate() calls,
// then asserts: no deadlock/crash, no torn reads (every readable key returns
// its last written value or not-found — never garbage), and that a final
// truncate leaves count()==0 with the reserved master_id preserved.
// ---------------------------------------------------------------------------

namespace {
	struct set_loop_arg {
		storage_rocksdb* s;
		int iterations;
		int num_keys;
	};

	// Writes keys key0..key{num_keys-1} = "vN" on each iteration, where N is
	// the iteration index, so the last value written for keyK is
	// "v{iterations-1}". Runs concurrently with truncate() on the main thread.
	void* set_loop(void* raw) {
		set_loop_arg* a = static_cast<set_loop_arg*>(raw);
		for (int i = 0; i < a->iterations; i++) {
			char val[32];
			snprintf(val, sizeof(val), "v%d", i);
			for (int k = 0; k < a->num_keys; k++) {
				char key[32];
				snprintf(key, sizeof(key), "key%d", k);
				storage_set_string(a->s, key, val);
			}
		}
		return NULL;
	}
}

void test_concurrent_truncate_and_set() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	// master_id must exist before we start so we can assert it survives.
	cut_assert_operator(s->get_master_id().empty(), ==, false);

	const int iterations = 200;
	const int num_keys   = 8;
	set_loop_arg arg = { s, iterations, num_keys };

	pthread_t writer;
	cut_assert_equal_int(0, pthread_create(&writer, NULL, set_loop, &arg));

	// Interleave a handful of truncates while the writer runs. Each
	// truncate must acquire the wholelock, proving mutual exclusion holds
	// without deadlocking against the concurrent set()s.
	for (int t = 0; t < 5; t++) {
		cut_assert_equal_int(0, s->truncate(0));
		usleep(1000);
	}

	cut_assert_equal_int(0, pthread_join(writer, NULL));

	// Consistency: any key still present must read back a value the writer
	// actually wrote ("v0".."v{iterations-1}"), never a torn/garbage value.
	for (int k = 0; k < num_keys; k++) {
		char key[32];
		snprintf(key, sizeof(key), "key%d", k);
		string out;
		int rc = storage_get_string(s, key, out);
		if (rc == 0) {
			cut_assert_equal_int('v', out.empty() ? 0 : out[0]);
			bool numeric = out.size() >= 2;
			for (size_t i = 1; numeric && i < out.size(); i++) {
				if (out[i] < '0' || out[i] > '9') numeric = false;
			}
			cut_assert_operator(numeric, ==, true);
		}
	}

	// A final truncate with no concurrent writer: storage is empty of user
	// keys, and the reserved master_id lineage token is preserved.
	cut_assert_equal_int(0, s->truncate(0));
	cut_assert_equal_int(0, static_cast<int>(s->count()));
	cut_assert_operator(s->get_master_id().empty(), ==, false);

	drop_rocksdb(s, wal_master_dir);
}

// ---------------------------------------------------------------------------
// Orphan scan token TTL expiry
//
// lookup_orphan_scan() rejects a token once it is older than the configured
// TTL window. Drive it fast by shrinking the window to 1 second.
// ---------------------------------------------------------------------------

void test_phaseC_orphan_scan_token_expires_after_ttl() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	s->set_orphan_scan_ttl_seconds(1);

	string t = s->remember_orphan_scan(9, 3, 300);
	storage_rocksdb::orphan_scan_token out;
	// Valid immediately after issue.
	cut_assert_equal_int(1, s->lookup_orphan_scan(t, out) ? 1 : 0);

	// After the TTL window elapses the same token is no longer actionable.
	sleep(2);
	cut_assert_equal_int(0, s->lookup_orphan_scan(t, out) ? 1 : 0);

	drop_rocksdb(s, wal_master_dir);
}

// ---------------------------------------------------------------------------
// Named backups (RocksDB checkpoints) + retention
// ---------------------------------------------------------------------------

namespace {
	// Count immediate subdirectories of a path (used to check retention).
	int count_subdirs(const string& path) {
		DIR* d = opendir(path.c_str());
		if (d == NULL) {
			return -1;
		}
		int n = 0;
		struct dirent* ent;
		while ((ent = readdir(d)) != NULL) {
			string name = ent->d_name;
			if (name == "." || name == "..") {
				continue;
			}
			struct stat st;
			string child = path + "/" + name;
			if (lstat(child.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
				n++;
			}
		}
		closedir(d);
		return n;
	}

	bool path_is_dir(const string& path) {
		struct stat st;
		return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
	}

	bool path_exists(const string& path) {
		struct stat st;
		return stat(path.c_str(), &st) == 0;
	}
}

// A backup of a populated DB produces a complete, openable checkpoint dir
// (has a CURRENT file) from which the written key is readable.
void test_backup_create_and_read_back() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, storage_set_string(s, "hello", "world"));

	string out_path;
	cut_assert_equal_int(0, s->create_named_backup("20260712-000000", out_path));
	cut_assert_operator(out_path.empty(), ==, false);
	cut_assert_operator(path_is_dir(out_path), ==, true);
	// A RocksDB directory always has a CURRENT manifest pointer.
	cut_assert_operator(path_exists(out_path + "/CURRENT"), ==, true);

	// Open the checkpoint as a standalone read-only RocksDB and confirm the
	// key is present. The stored value carries storage_rocksdb's serialized
	// header prefix, so we assert the payload appears at the tail rather
	// than doing an exact-equals on the raw bytes.
	rocksdb::DB* raw = NULL;
	rocksdb::Options opt;
	opt.create_if_missing = false;
	rocksdb::Status st = rocksdb::DB::OpenForReadOnly(opt, out_path, &raw);
	cut_assert_operator(st.ok(), ==, true);
	string val;
	rocksdb::Status g = raw->Get(rocksdb::ReadOptions(), "hello", &val);
	cut_assert_operator(g.ok(), ==, true);
	cut_assert_operator(val.size() >= 5, ==, true);
	cut_assert_equal_string("world", val.substr(val.size() - 5).c_str());
	delete raw;

	// Success is reflected in the counters / epoch.
	cut_assert_equal_int(1, static_cast<int>(s->get_backup_success()));
	cut_assert_operator(s->get_last_backup_epoch(), >, static_cast<time_t>(0));

	drop_rocksdb(s, wal_master_dir);
}

// Names that could escape the backups/ directory (or are otherwise invalid)
// are rejected and create nothing.
void test_backup_rejects_invalid_names() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	const char* bad[] = { "../evil", "a/b", "", ".hidden" };
	for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
		string out_path;
		cut_assert_equal_int(-1, s->create_named_backup(bad[i], out_path));
	}
	// Every rejection bumped the failure counter; nothing succeeded.
	cut_assert_equal_int(0, static_cast<int>(s->get_backup_success()));
	cut_assert_equal_int(4, static_cast<int>(s->get_backup_failure()));
	// No backups directory content was produced by the invalid names. (A
	// backups/ dir may not even exist; count_subdirs returns -1 then.)
	string backups = string(wal_master_dir) + "/backups";
	int n = count_subdirs(backups);
	cut_assert_operator(n <= 0, ==, true);

	drop_rocksdb(s, wal_master_dir);
}

// With _backup_keep=2, creating 4 backups leaves only the 2 newest (by
// sortable name order).
void test_backup_retention_prunes_oldest() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	s->set_backup_keep(2);
	cut_assert_equal_int(0, storage_set_string(s, "k", "v"));

	const char* names[] = {
		"20260712-000001",
		"20260712-000002",
		"20260712-000003",
		"20260712-000004",
	};
	for (size_t i = 0; i < 4; i++) {
		string out_path;
		cut_assert_equal_int(0, s->create_named_backup(names[i], out_path));
	}

	string backups = string(wal_master_dir) + "/backups";
	cut_assert_equal_int(2, count_subdirs(backups));
	// The two newest survive; the two oldest are pruned.
	cut_assert_operator(path_is_dir(backups + "/20260712-000003"), ==, true);
	cut_assert_operator(path_is_dir(backups + "/20260712-000004"), ==, true);
	cut_assert_operator(path_exists(backups + "/20260712-000001"), ==, false);
	cut_assert_operator(path_exists(backups + "/20260712-000002"), ==, false);

	drop_rocksdb(s, wal_master_dir);
}

// Pruning must run BEFORE checkpoint creation: on a nearly-full disk the
// old checkpoints are exactly what blocks the new one, and a post-create
// prune never runs when the create fails (observed live: hourly backups
// wedged a 100%-full tmpfs forever). Force the create to fail by
// pre-creating the target dir (CreateCheckpoint refuses to overwrite) and
// assert the oldest backup was still pruned.
void test_backup_prune_runs_before_create() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	s->set_backup_keep(2);
	cut_assert_equal_int(0, storage_set_string(s, "k", "v"));

	string out_path;
	cut_assert_equal_int(0, s->create_named_backup("20260712-000001", out_path));

	string backups = string(wal_master_dir) + "/backups";
	// "zzz" sorts last (newest), so the pre-create prune (keep-1 = 1)
	// removes 20260712-000001 before the create attempt fails on the
	// pre-existing target dir.
	cut_assert_equal_int(0, mkdir((backups + "/zzz-existing").c_str(), 0700));
	cut_assert_equal_int(-1, s->create_named_backup("zzz-existing", out_path));

	cut_assert_operator(path_exists(backups + "/20260712-000001"), ==, false);

	drop_rocksdb(s, wal_master_dir);
}

// ---------------------------------------------------------------------------
// Replication cursor seeding (set_repl_last_lsn)
// ---------------------------------------------------------------------------

// set_repl_last_lsn writes the cursor durably; get_repl_last_lsn reads it back.
void test_set_repl_last_lsn_roundtrip() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, static_cast<int>(s->get_repl_last_lsn()));  // fresh DB: 0
	cut_assert_equal_int(0, s->set_repl_last_lsn(42));
	cppcut_assert_equal(static_cast<uint64_t>(42), s->get_repl_last_lsn());
	drop_rocksdb(s, wal_master_dir);
}

// The seeded cursor survives a close/open cycle (durable Put).
void test_set_repl_last_lsn_survives_reopen() {
	storage_rocksdb* s1 = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, s1->set_repl_last_lsn(123456));
	drop_rocksdb_noremove(s1);

	storage_rocksdb* s2 = new storage_rocksdb(
		wal_master_dir, 32, 4, 16, 4, 2, 86400, 1024);
	cut_assert_equal_int(0, s2->open());
	cppcut_assert_equal(static_cast<uint64_t>(123456), s2->get_repl_last_lsn());
	s2->close();
	delete s2;
	cut_remove_path(wal_master_dir, NULL);
}

// truncate-before-full-dump flow used by handler_reconstruction: truncate
// clears user keys and resets the LSN cursor while preserving the master_id
// lineage token, and the cursor can then be re-seeded from the master's
// pre-dump LSN.
//
// NOTE: this exercises only the storage-level primitive. WHEN the handler
// actually truncates is a handler-level policy gated on THREE conditions
// (rocksdb backend AND target role == slave AND the pre-dump feature probe
// reached a live source); a master reconstruction or an unreachable source
// must NOT truncate (its local data may be the last copy). That gating is
// covered by the e2e pvc-data-survival suite, not here.
void test_truncate_then_reseed_repl_lsn() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	string master_id = s->get_master_id();
	cut_assert_operator(master_id.empty(), ==, false);

	cut_assert_equal_int(0, storage_set_string(s, "a", "1"));
	cut_assert_equal_int(0, storage_set_string(s, "b", "2"));
	cut_assert_equal_int(0, s->set_repl_last_lsn(5));
	cut_assert_operator(s->count(), >, static_cast<uint32_t>(0));

	// truncate: user keys gone, LSN reset to 0, master_id preserved.
	cut_assert_equal_int(0, s->truncate(0));
	cut_assert_equal_int(0, static_cast<int>(s->count()));
	cut_assert_equal_int(0, static_cast<int>(s->get_repl_last_lsn()));
	cut_assert_equal_string(master_id.c_str(), s->get_master_id().c_str());

	// re-seed the cursor from the master's pre-dump LSN (as the handler does).
	cut_assert_equal_int(0, s->set_repl_last_lsn(9));
	cppcut_assert_equal(static_cast<uint64_t>(9), s->get_repl_last_lsn());

	drop_rocksdb(s, wal_master_dir);
}

// ---------------------------------------------------------------------------
// Expire reaping: lazy delete-on-get + background crawler (reap_expired).
//
// RocksDB has no lazy-expiry-on-get (unlike storage_tch) nor any TTL sweep, so
// past-expire keys used to linger forever. A compaction filter can't fix it
// under WAL replication (its drops bypass the WAL and diverge slaves), so the
// master reaps with real deletes that replicate. These tests pin both paths.
// ---------------------------------------------------------------------------
namespace {
	// set a key carrying an explicit expire (epoch seconds; 0 = never expires).
	int storage_set_string_expire(storage* s, const string& key, const string& value, time_t expire) {
		storage::entry e;
		e.key = key;
		e.flag = 0;
		e.expire = expire;
		e.version = 0;   // let storage assign
		e.size = value.size();
		shared_byte data(new uint8_t[value.size()]);
		memcpy(data.get(), value.data(), value.size());
		e.data = data;
		storage::result r;
		return s->set(e, r, 0);
	}
}

// A get() landing on an expired entry returns NOT_FOUND *and* physically
// removes it (mirrors storage_tch) so its space is reclaimed.
void test_expire_lazy_delete_on_get() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	// expire=1 => 1970, always past relative to the live timestamp.
	cut_assert_equal_int(0, storage_set_string_expire(s, "k", "v", 1));
	cut_assert_equal_int(1, static_cast<int>(s->count()));            // physically present
	cut_assert_equal_int(0, static_cast<int>(s->get_expire_reaped()));

	string out;
	cut_assert_equal_int(-1, storage_get_string(s, "k", out));       // observes expiry

	cut_assert_equal_int(0, static_cast<int>(s->count()));           // physically gone
	cut_assert_equal_int(1, static_cast<int>(s->get_expire_reaped()));

	drop_rocksdb(s, wal_master_dir);
}

// reap_expired deletes only past-expire entries, keeps live/never-expire ones,
// and reports accurate counts.
void test_expire_reap_removes_only_expired() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	time_t now = stats_object->get_timestamp();
	cut_assert_equal_int(0, storage_set_string_expire(s, "past",   "v", now - 10));  // expired
	cut_assert_equal_int(0, storage_set_string_expire(s, "never",  "v", 0));         // never
	cut_assert_equal_int(0, storage_set_string_expire(s, "future", "v", now + 1000));// not yet
	cut_assert_equal_int(3, static_cast<int>(s->count()));

	uint32_t scanned = 0, reaped = 0;
	bool more = true;
	string last;
	cut_assert_equal_int(0, s->reap_expired(now, 100, "", last, more, scanned, reaped));

	cut_assert_equal_int(1, static_cast<int>(reaped));
	cppcut_assert_equal(false, more);                          // whole keyspace in one chunk
	cut_assert_equal_int(2, static_cast<int>(s->count()));
	cut_assert_equal_int(1, static_cast<int>(s->get_expire_reaped()));

	string out;
	cut_assert_equal_int(-1, storage_get_string(s, "past", out));    // gone
	cut_assert_equal_int(0,  storage_get_string(s, "never", out));   // kept
	cut_assert_equal_int(0,  storage_get_string(s, "future", out));  // kept

	drop_rocksdb(s, wal_master_dir);
}

// A chunked sweep (small max_scan) drains the whole keyspace across calls,
// resuming strictly after each chunk's last key.
void test_expire_reap_chunked_sweep() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	time_t now = stats_object->get_timestamp();
	const int n = 25;
	for (int i = 0; i < n; i++) {
		char k[32];
		snprintf(k, sizeof(k), "e%03d", i);
		cut_assert_equal_int(0, storage_set_string_expire(s, k, "v", now - 5));
	}
	cut_assert_equal_int(n, static_cast<int>(s->count()));

	uint64_t total_reaped = 0;
	string after = "";
	bool more = true;
	int guard = 0;
	while (more && guard++ < 1000) {
		uint32_t scanned = 0, reaped = 0;
		string last;
		cut_assert_equal_int(0, s->reap_expired(now, 10, after, last, more, scanned, reaped));
		total_reaped += reaped;
		after = last;
	}
	cut_assert_equal_int(n, static_cast<int>(total_reaped));
	cut_assert_equal_int(0, static_cast<int>(s->count()));

	drop_rocksdb(s, wal_master_dir);
}

// reap_expired reports every key it deleted, with the version it deleted at,
// so handler_reaper can forward them as version-carrying deletes to slaves
// (the storage-level remove itself is local). Refreshed keys are NOT reported.
void test_expire_reap_reports_reaped_entries() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	time_t now = stats_object->get_timestamp();
	cut_assert_equal_int(0, storage_set_string_expire(s, "gone1", "v", now - 5));
	cut_assert_equal_int(0, storage_set_string_expire(s, "gone2", "v", now - 5));
	cut_assert_equal_int(0, storage_set_string_expire(s, "alive", "v", now + 3600));
	cut_assert_equal_int(0, storage_set_string_expire(s, "never", "v", 0));

	vector<storage::entry> reported;
	string after = "", last;
	bool more = true;
	uint32_t scanned = 0, reaped = 0;
	cut_assert_equal_int(0, s->reap_expired(now, 100, after, last, more, scanned, reaped, &reported));
	cut_assert_equal_int(2, static_cast<int>(reaped));
	cut_assert_equal_int(2, static_cast<int>(reported.size()));
	for (size_t i = 0; i < reported.size(); i++) {
		cut_assert_true(reported[i].key == "gone1" || reported[i].key == "gone2");
		cut_assert_true(reported[i].version > 0);   // carries the version it deleted at
	}
	cut_assert_equal_int(2, static_cast<int>(s->count()));

	drop_rocksdb(s, wal_master_dir);
}

// reap_expired must NOT delete a key whose expire was refreshed into the future
// (a re-set before the sweep): only genuinely past-expire entries go.
void test_expire_reap_skips_refreshed_key() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	time_t now = stats_object->get_timestamp();
	cut_assert_equal_int(0, storage_set_string_expire(s, "k", "old", now - 10));
	// re-set with a future expire (new version) before the sweep.
	cut_assert_equal_int(0, storage_set_string_expire(s, "k", "new", now + 1000));

	uint32_t scanned = 0, reaped = 0;
	bool more = true;
	string last;
	cut_assert_equal_int(0, s->reap_expired(now, 100, "", last, more, scanned, reaped));

	cut_assert_equal_int(0, static_cast<int>(reaped));
	cut_assert_equal_int(1, static_cast<int>(s->count()));

	string out;
	cut_assert_equal_int(0, storage_get_string(s, "k", out));
	cut_assert_equal_string("new", out.c_str());

	drop_rocksdb(s, wal_master_dir);
}

// ---------------------------------------------------------------------------
// Snapshot bootstrap: checkpoint (with exact sequence) -> transfer -> swap ->
// WAL catch-up. Pins the storage-layer contract behind op_repl_snapshot: the
// swapped-in DB must carry the source's data, lineage token and an exact
// replication cursor, such that a subsequent incremental WAL sync delivers
// precisely the post-checkpoint tail. The wire transfer itself is exercised
// by E2E (every fresh-slave reconstruction now goes snapshot-first).
// ---------------------------------------------------------------------------

namespace {
	int copy_dir_flat(const string& src, const string& dst) {
		DIR* d = opendir(src.c_str());
		if (d == NULL) return -1;
		struct dirent* ent;
		int r = 0;
		while ((ent = readdir(d)) != NULL) {
			string n = ent->d_name;
			if (n == "." || n == "..") continue;
			struct stat st;
			string from = src + "/" + n;
			if (stat(from.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) continue;
			FILE* in = fopen(from.c_str(), "rb");
			FILE* out = fopen((dst + "/" + n).c_str(), "wb");
			if (in == NULL || out == NULL) { if (in) fclose(in); if (out) fclose(out); r = -1; break; }
			char buf[65536];
			size_t got;
			while ((got = fread(buf, 1, sizeof(buf), in)) > 0) {
				if (fwrite(buf, 1, got, out) != got) { r = -1; break; }
			}
			fclose(in); fclose(out);
			if (r != 0) break;
		}
		closedir(d);
		return r;
	}
}

void test_snapshot_bootstrap_checkpoint_swap_and_wal_catchup() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave  = make_rocksdb(wal_slave_dir);

	const int n = 100;
	for (int i = 0; i < n; i++) {
		char k[32];
		snprintf(k, sizeof(k), "snap%03d", i);
		cut_assert_equal_int(0, storage_set_string(master, k, "v"));
	}

	// Checkpoint captures data + the EXACT sequence number.
	string cp_path;
	uint64_t cp_seq = 0;
	cut_assert_equal_int(0, master->create_snapshot_checkpoint(cp_path, cp_seq));
	cut_assert_operator(cp_seq, >, static_cast<uint64_t>(0));

	// Post-checkpoint tail: must arrive via WAL catch-up, not the files.
	cut_assert_equal_int(0, storage_set_string(master, "after1", "tail"));
	cut_assert_equal_int(0, storage_set_string(master, "after2", "tail"));

	// "Transfer" the files (unit-level stand-in for the wire op).
	string staging;
	cut_assert_equal_int(0, slave->prepare_snapshot_staging(staging));
	cut_assert_equal_int(0, copy_dir_flat(cp_path, staging));
	cut_assert_equal_int(0, master->remove_snapshot_checkpoint(cp_path));

	// Swap in: data, lineage, cursor and the O(1) counter must all be right.
	cut_assert_equal_int(0, slave->swap_in_snapshot(staging, cp_seq));
	cppcut_assert_equal(cp_seq, slave->get_repl_last_lsn());
	cut_assert_equal_string(master->get_master_id().c_str(), slave->get_master_id().c_str());
	string out;
	cut_assert_equal_int(0, storage_get_string(slave, "snap000", out));
	cut_assert_equal_int(-1, storage_get_string(slave, "after1", out));   // tail not in files
	cut_assert_equal_int(n, static_cast<int>(slave->count()));            // exact reseed incl. WAL-only keys

	// WAL catch-up from the checkpoint sequence delivers exactly the tail.
	cut_assert_operator(replicate_from(master, slave, cp_seq), >=, 2);
	cut_assert_equal_int(0, storage_get_string(slave, "after1", out));
	cut_assert_equal_string("tail", out.c_str());
	cut_assert_equal_int(0, storage_get_string(slave, "after2", out));
	cut_assert_equal_int(n + 2, static_cast<int>(slave->count()));

	drop_rocksdb(master, wal_master_dir);
	drop_rocksdb(slave,  wal_slave_dir);
}

// validate_batch_rep(): structural walk without applying — senders use it to
// refuse to stream a batch that was already corrupt at WAL-read time.
void test_validate_batch_rep() {
	rocksdb::WriteBatch good;
	good.Put("k", "v");
	good.Delete("gone");
	cut_assert_true(storage_rocksdb::validate_batch_rep(good));

	string rep(12, '\0');
	rep[8] = 1;              // count = 1
	rep += '\xf7';           // unknown record tag
	rocksdb::WriteBatch bad(rep);
	cut_assert_false(storage_rocksdb::validate_batch_rep(bad));
}

// A corrupt INCOMING batch latches the corruption flag, but a successful
// snapshot swap replaces the DB wholesale — the latch must clear with it.
// (Observed live: slaves that failed WAL sync on a corrupt batch, then
// reseeded cleanly via snapshot bootstrap, kept paging rocksdb_corrupted=1.)
void test_swap_in_snapshot_clears_corruption_latch() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave  = make_rocksdb(wal_slave_dir);
	cut_assert_equal_int(0, storage_set_string(master, "k1", "v1"));

	// Garbage WriteBatch: valid 12-byte header (seq=0, count=1) + a bogus
	// record tag. Write() rejects it with Corruption and the latch sets.
	string rep(12, '\0');
	rep[8] = 1;              // count = 1 (little-endian)
	rep += '\xf7';           // unknown record tag
	rocksdb::WriteBatch bad(rep);
	cut_assert_operator(slave->apply_batch_with_lsn(bad, 1), <, 0);
	cut_assert_true(slave->is_corrupted());
	cut_assert_operator(slave->get_corruption_detected(), >, static_cast<uint64_t>(0));

	// Clean snapshot swap-in -> latch must clear.
	string cp_path;
	uint64_t cp_seq = 0;
	cut_assert_equal_int(0, master->create_snapshot_checkpoint(cp_path, cp_seq));
	string staging;
	cut_assert_equal_int(0, slave->prepare_snapshot_staging(staging));
	cut_assert_equal_int(0, copy_dir_flat(cp_path, staging));
	cut_assert_equal_int(0, master->remove_snapshot_checkpoint(cp_path));
	cut_assert_equal_int(0, slave->swap_in_snapshot(staging, cp_seq));
	cut_assert_false(slave->is_corrupted());
	string out;
	cut_assert_equal_int(0, storage_get_string(slave, "k1", out));

	drop_rocksdb(master, wal_master_dir);
	drop_rocksdb(slave,  wal_slave_dir);
}

// analyze_checkpoint(): open a checkpoint READ-ONLY and stream one CSV row per
// live key (key,expire,ttl,size). Exercises the inline path, the BLOB path
// (values >= min_blob_size 4096 live in blob files and must be dereferenced),
// an explicit expire, and reserved-key filtering.
void test_analyze_checkpoint_streams_key_expire_size() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, storage_set_string(s, "small", "hello"));   // inline, size 5
	string big(5000, 'x');
	cut_assert_equal_int(0, storage_set_string(s, "big", big));         // >=4096 -> blob file
	{
		storage::entry e;
		e.key = "withexp"; e.flag = 0; e.expire = time(NULL) + 3600; e.version = 0;
		e.size = 3;
		shared_byte d(new uint8_t[3]); memcpy(d.get(), "abc", 3); e.data = d;
		storage::result r;
		cut_assert_equal_int(0, s->set(e, r, 0));
	}

	// The real analyze input is a checkpoint (an S3 backup copy in production).
	string cp; uint64_t seq = 0;
	cut_assert_equal_int(0, s->create_snapshot_checkpoint(cp, seq));

	FILE* f = tmpfile();
	cut_assert_not_null(f);
	cut_assert_equal_int(0, s->analyze_checkpoint(cp, f));

	rewind(f);
	string out;
	char buf[4096]; size_t n;
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.append(buf, n);
	fclose(f);

	cut_assert_true(out.find("key,expire,ttl,size") != string::npos);
	cut_assert_true(out.find("\"small\",0,-1,5") != string::npos);      // no expire -> ttl -1
	cut_assert_true(out.find("\"big\",0,-1,5000") != string::npos);      // blob value, exact length
	cut_assert_true(out.find("\"withexp\",") != string::npos);
	// header + exactly 3 data rows: reserved replication keys are filtered out
	int rows = 0; size_t pos = 0;
	while ((pos = out.find('\n', pos)) != string::npos) { rows++; pos++; }
	cppcut_assert_equal(4, rows);

	s->remove_snapshot_checkpoint(cp);
	drop_rocksdb(s, wal_master_dir);
}

// hard_reset(): the in-process Case-A recovery must wipe all data, clear the
// corruption latch, keep the DB usable, and reset curr_items to 0.
void test_hard_reset_wipes_and_recovers() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, storage_set_string(s, "a", "alpha"));
	cut_assert_equal_int(0, storage_set_string(s, "b", "bravo"));
	cut_assert_equal_int(2, static_cast<int>(s->count()));
	cut_assert_false(s->is_corrupted());

	cut_assert_equal_int(0, s->hard_reset());

	// data gone, counter reset, DB still writable
	cut_assert_equal_int(0, static_cast<int>(s->count()));
	string out;
	cut_assert_operator(storage_get_string(s, "a", out), !=, 0);
	cut_assert_false(s->is_corrupted());
	cut_assert_operator(s->get_hard_reset(), >, static_cast<uint64_t>(0));
	cut_assert_equal_int(0, storage_set_string(s, "fresh", "value"));
	cut_assert_equal_int(0, storage_get_string(s, "fresh", out));
	cut_assert_equal_string("value", out.c_str());

	drop_rocksdb(s, wal_master_dir);
}

// verify_integrity() on a healthy DB reports clean and does not latch.
void test_verify_integrity_clean() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, storage_set_string(s, "k", "v"));
	cut_assert_equal_int(0, s->verify_integrity());
	cut_assert_false(s->is_corrupted());
	cut_assert_equal_int(0, static_cast<int>(s->get_corruption_detected()));
	drop_rocksdb(s, wal_master_dir);
}

// ---------------------------------------------------------------------------
// SAF-10b stage 1: generation identities and the all-or-nothing restore.
//
// These pin the four defects found in review of the first cut: a per-node
// counter cannot distinguish two histories (sequential promotion), a repeated
// reset returns to the same value, a failed persist left the node advertising
// an unchanged identity over changed data, and a failed cleanup at a restore
// boundary could still expose a half-restored copy.
// ---------------------------------------------------------------------------

namespace {
	// The sentinel swap_in_snapshot writes beside the DB directory.
	string restore_sentinel(const char* dir) {
		return string(dir) + "/.flare_restore_pending";
	}
}

// Two SEPARATE copies, each promoted in turn, must never advertise the same
// source epoch: their sequence spaces are unrelated, and a follower comparing
// numbers across them would apply one history's positions against another's.
void test_generation_epoch_unique_across_sequential_promotions() {
	storage_rocksdb* a = make_rocksdb(wal_master_dir);
	storage_rocksdb* b = make_rocksdb(wal_slave_dir);

	const string a0 = a->get_source_epoch();
	const string b0 = b->get_source_epoch();
	cut_assert_operator(a0.size(), >, static_cast<size_t>(0));
	cut_assert_operator(b0.size(), >, static_cast<size_t>(0));
	cut_assert_not_equal_string(a0.c_str(), b0.c_str());

	// Promote A, then promote B — the same number of advances on each.
	cut_assert_equal_int(0, a->advance_source_epoch());
	cut_assert_equal_int(0, b->advance_source_epoch());
	const string a1 = a->get_source_epoch();
	const string b1 = b->get_source_epoch();
	cut_assert_not_equal_string(a1.c_str(), a0.c_str());
	cut_assert_not_equal_string(b1.c_str(), b0.c_str());
	// The point of the test: equal advance counts, different identities.
	cut_assert_not_equal_string(a1.c_str(), b1.c_str());

	drop_rocksdb(a, wal_master_dir);
	drop_rocksdb(b, wal_slave_dir);
}

// A repeated hard reset must mint a NEW incarnation every time. With a
// counter, each reset re-initialised an empty DB and produced the same value,
// so a delivery issued against the previous copy would be accepted.
void test_generation_incarnation_unique_across_repeated_hard_reset() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string i0 = s->get_incarnation();
	const string e0 = s->get_source_epoch();
	cut_assert_operator(i0.size(), >, static_cast<size_t>(0));

	cut_assert_equal_int(0, s->hard_reset());
	const string i1 = s->get_incarnation();
	const string e1 = s->get_source_epoch();
	cut_assert_not_equal_string(i1.c_str(), i0.c_str());
	cut_assert_not_equal_string(e1.c_str(), e0.c_str());   // its history is gone too

	cut_assert_equal_int(0, s->hard_reset());
	const string i2 = s->get_incarnation();
	cut_assert_not_equal_string(i2.c_str(), i1.c_str());
	cut_assert_not_equal_string(i2.c_str(), i0.c_str());

	drop_rocksdb(s, wal_master_dir);
}

// Both identities survive a plain reopen unchanged: a process restart is not
// a history change and must not cost a rebuild.
void test_generations_survive_reopen() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string e = s->get_source_epoch();
	const string i = s->get_incarnation();
	drop_rocksdb_noremove(s);

	s = make_rocksdb(wal_master_dir);
	cut_assert_equal_string(e.c_str(), s->get_source_epoch().c_str());
	cut_assert_equal_string(i.c_str(), s->get_incarnation().c_str());
	cut_assert_false(s->generations_broken());
	drop_rocksdb(s, wal_master_dir);
}

// A generation that cannot be persisted must leave the node UNAVAILABLE for
// replication, not advertising the old identity over changed data.
void test_generation_persist_failure_is_fail_closed() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_operator(s->get_source_epoch().size(), >, static_cast<size_t>(0));

	// Closing the handle makes every persist fail, which is the observable
	// stand-in for a write error at the moment of the advance.
	s->close();
	cut_assert_equal_int(-1, s->advance_source_epoch());
	cut_assert_true(s->generations_broken());
	cut_assert_equal_string("", s->get_source_epoch().c_str());
	cut_assert_equal_string("", s->get_incarnation().c_str());

	delete s;
	s = NULL;
	cut_remove_path(wal_master_dir, NULL);
}

// A restore interrupted anywhere between "old copy destroyed" and "cursor,
// generations and marker committed" leaves the sentinel behind; the next open
// must discard that copy rather than expose the source's data with our
// metadata unset.
void test_restore_sentinel_discards_half_restored_copy() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, storage_set_string(s, "survivor", "v"));
	const string before = s->get_incarnation();
	drop_rocksdb_noremove(s);

	// Simulate the crash window: the sentinel is on disk, the DB is not ours.
	FILE* fp = fopen(restore_sentinel(wal_master_dir).c_str(), "w");
	cut_assert_not_null(fp);
	fclose(fp);

	s = make_rocksdb(wal_master_dir);
	string out;
	cut_assert_operator(storage_get_string(s, "survivor", out), !=, 0);   // discarded
	cut_assert_equal_int(0, static_cast<int>(s->count()));
	cut_assert_operator(s->get_incarnation().size(), >, static_cast<size_t>(0));
	cut_assert_not_equal_string(before.c_str(), s->get_incarnation().c_str());
	cut_assert_false(s->generations_broken());
	drop_rocksdb(s, wal_master_dir);
}

// If the sentinel itself cannot be cleared, opening would discard the NEXT
// (good) restore as well, so open must refuse instead. A directory in its
// place makes unlink() fail deterministically.
void test_restore_sentinel_unremovable_refuses_open() {
	mkdir(wal_master_dir, 0700);
	cut_assert_equal_int(0, mkdir(restore_sentinel(wal_master_dir).c_str(), 0700));

	storage_rocksdb* s = new storage_rocksdb(wal_master_dir, 32, 4, 16, 4, 2, 86400, 1024);
	cut_assert_equal_int(-1, s->open());
	delete s;

	rmdir(restore_sentinel(wal_master_dir).c_str());
	cut_remove_path(wal_master_dir, NULL);
}

// A checkpoint that carries no source epoch cannot be identified, so the
// restore must be refused rather than completed against an unknown history.
void test_swap_in_snapshot_refuses_checkpoint_without_source_epoch() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave  = make_rocksdb(wal_slave_dir);
	cut_assert_equal_int(0, storage_set_string(master, "k", "v"));

	string cp_path;
	uint64_t cp_seq = 0;
	cut_assert_equal_int(0, master->create_snapshot_checkpoint(cp_path, cp_seq));

	string staging;
	cut_assert_equal_int(0, slave->prepare_snapshot_staging(staging));
	cut_assert_equal_int(0, copy_dir_flat(cp_path, staging));
	cut_assert_equal_int(0, master->remove_snapshot_checkpoint(cp_path));

	// Strip the identity from the staged copy: open it and delete the key.
	// Every column family the checkpoint carries must be listed — it now has
	// the replication-metadata one as well.
	{
		rocksdb::DB* db = NULL;
		rocksdb::Options o;
		o.create_if_missing = false;
		vector<string> names;
		cut_assert_true(rocksdb::DB::ListColumnFamilies(rocksdb::DBOptions(o), staging, &names).ok());
		vector<rocksdb::ColumnFamilyDescriptor> descriptors;
		for (size_t i = 0; i < names.size(); i++) {
			descriptors.push_back(rocksdb::ColumnFamilyDescriptor(names[i], rocksdb::ColumnFamilyOptions(o)));
		}
		vector<rocksdb::ColumnFamilyHandle*> handles;
		cut_assert_true(rocksdb::DB::Open(rocksdb::DBOptions(o), staging, descriptors, &handles, &db).ok());
		cut_assert_true(db->Delete(rocksdb::WriteOptions(), storage_rocksdb::kReplSourceEpochKey).ok());
		for (size_t i = 0; i < handles.size(); i++) {
			db->DestroyColumnFamilyHandle(handles[i]);
		}
		delete db;
	}

	const string before = slave->get_incarnation();
	cut_assert_operator(slave->swap_in_snapshot(staging, cp_seq), <, 0);
	// Refused: the identity did not move, and the node is not left claiming
	// a cursor for a history it cannot name.
	cut_assert_equal_string(before.c_str(), slave->get_incarnation().c_str());

	drop_rocksdb(master, wal_master_dir);
	drop_rocksdb(slave,  wal_slave_dir);
}

// A successful restore inherits the source's epoch and mints a FRESH
// incarnation; restoring twice must not reuse the identity.
void test_restore_inherits_epoch_and_mints_incarnation() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave  = make_rocksdb(wal_slave_dir);
	cut_assert_equal_int(0, storage_set_string(master, "k", "v"));

	string incarnations[2];
	for (int round = 0; round < 2; round++) {
		string cp_path;
		uint64_t cp_seq = 0;
		cut_assert_equal_int(0, master->create_snapshot_checkpoint(cp_path, cp_seq));
		string staging;
		cut_assert_equal_int(0, slave->prepare_snapshot_staging(staging));
		cut_assert_equal_int(0, copy_dir_flat(cp_path, staging));
		cut_assert_equal_int(0, master->remove_snapshot_checkpoint(cp_path));
		cut_assert_equal_int(0, slave->swap_in_snapshot(staging, cp_seq));

		cut_assert_equal_string(master->get_source_epoch().c_str(), slave->get_source_epoch().c_str());
		incarnations[round] = slave->get_incarnation();
		cut_assert_operator(incarnations[round].size(), >, static_cast<size_t>(0));
		// The sentinel must be gone once the restore completed.
		struct stat sb;
		cut_assert_operator(stat(restore_sentinel(wal_slave_dir).c_str(), &sb), !=, 0);
	}
	cut_assert_not_equal_string(incarnations[0].c_str(), incarnations[1].c_str());

	drop_rocksdb(master, wal_master_dir);
	drop_rocksdb(slave,  wal_slave_dir);
}

// truncate() replaces the history, so followers must see a different source
// epoch rather than a silently rewritten one.
void test_truncate_advances_source_epoch() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	cut_assert_equal_int(0, storage_set_string(s, "k", "v"));
	const string before = s->get_source_epoch();
	cut_assert_equal_int(0, s->truncate());
	cut_assert_not_equal_string(before.c_str(), s->get_source_epoch().c_str());
	drop_rocksdb(s, wal_master_dir);
}

// The order label is captured inside the key's critical section, so the next
// change to the SAME key always carries a strictly greater one — including
// the delete that follows a set, which is the resurrection counterexample.
void test_order_label_strictly_monotonic_per_key() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);

	storage::entry e1;
	e1.key = "k";
	e1.size = 1;
	e1.data = shared_byte(new uint8_t[1]);
	e1.data.get()[0] = 'a';
	storage::result r;
	cut_assert_equal_int(0, s->set(e1, r));
	cut_assert_operator(e1.seq_label, >, static_cast<uint64_t>(0));

	// An unrelated key's write may inflate the label, which is allowed.
	storage_set_string(s, "other", "x");

	storage::entry e2;
	e2.key = "k";
	storage::result r2;
	cut_assert_equal_int(0, s->remove(e2, r2));
	cut_assert_operator(e2.seq_label, >, e1.seq_label);

	drop_rocksdb(s, wal_master_dir);
}

// ---------------------------------------------------------------------------
// SAF-10b stage 2: the common apply rule (design §3.3 / §3.4 / §3.5).
//
// Both delivery paths reach storage through it, so these pin the three
// hazards the reviewer named: a newer forwarded value overtaken by an older
// WAL delivery, a delete followed by an older put, and the position never
// advancing over something that was not applied.
// ---------------------------------------------------------------------------

namespace {
	// Build the serialized entry a forwarded change carries.
	void fill_entry(storage::entry& e, const char* key, const char* value) {
		e.key = key;
		e.size = strlen(value);
		e.data = shared_byte(new uint8_t[e.size > 0 ? e.size : 1]);
		memcpy(e.data.get(), value, e.size);
		e.flag = 0;
		e.expire = 0;
		e.version = 1;
	}

	// Pull the value bytes a real write produced out of the WAL, so a batch
	// built here carries exactly what the stream would carry — no assumption
	// about the on-disk header layout is baked into the tests.
	struct value_grabber : public rocksdb::WriteBatch::Handler {
		string want_key;
		string value;
		bool found;
		value_grabber(const string& k): want_key(k), found(false) {}
		rocksdb::Status PutCF(uint32_t cf, const rocksdb::Slice& key, const rocksdb::Slice& v) {
			if (cf == 0 && key.ToString() == this->want_key) {
				this->value = v.ToString();
				this->found = true;
			}
			return rocksdb::Status::OK();
		}
		rocksdb::Status DeleteCF(uint32_t, const rocksdb::Slice&) { return rocksdb::Status::OK(); }
		rocksdb::Status SingleDeleteCF(uint32_t, const rocksdb::Slice&) { return rocksdb::Status::OK(); }
		void LogData(const rocksdb::Slice&) {}
	};

	string serialized_entry(storage_rocksdb* scratch, const char* key, const char* value) {
		const uint64_t before = scratch->get_latest_sequence_number();
		cut_assert_equal_int(0, storage_set_string(scratch, key, value));
		vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
		cut_assert_equal_int(0, scratch->get_updates_since(before + 1, updates));
		value_grabber g(key);
		for (size_t i = 0; i < updates.size(); i++) {
			updates[i].second.Iterate(&g);
		}
		cut_assert_true(g.found);
		return g.value;
	}
}

// A newer value arrives by forwarding; the WAL then delivers an older change
// for the same key. The newer value must stand.
void test_apply_rule_forwarded_newer_survives_older_wal() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc = s->get_incarnation();
	const string inc_for_batch = inc;

	storage::entry e;
	fill_entry(e, "k", "new");
	cppcut_assert_equal(storage_rocksdb::apply_applied,
		s->apply_forwarded_change(epoch, inc, 100, e, false));

	// The stream has already been followed up to 89, so a batch at 90
	// continues it (a gap would be refused — see the gap test).
	cut_assert_equal_int(0, s->set_repl_last_lsn(89));

	// An older WAL change for the same key, delivered afterwards.
	storage_rocksdb* scratch = make_rocksdb(wal_slave_dir);
	const string old_bytes = serialized_entry(scratch, "k", "old");
	rocksdb::WriteBatch older;
	older.Put(rocksdb::Slice("k"), rocksdb::Slice(old_bytes));
	uint64_t applied = 0, skipped = 0;
	storage_rocksdb::apply_outcome refusal;
	cut_assert_equal_int(0, s->apply_wal_batch(epoch, inc_for_batch, 90, older, applied, skipped, refusal));
	cppcut_assert_equal(static_cast<uint64_t>(0), applied);
	cppcut_assert_equal(static_cast<uint64_t>(1), skipped);

	string out;
	cut_assert_equal_int(0, storage_get_string(s, "k", out));
	cut_assert_equal_string("new", out.c_str());
	drop_rocksdb(scratch, wal_slave_dir);
	drop_rocksdb(s, wal_master_dir);
}

// A delete, then an older put for the same key: the key stays deleted. This
// is the resurrection the in-memory header cache could not prevent.
void test_apply_rule_delete_then_older_put_does_not_resurrect() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc = s->get_incarnation();
	const string inc_for_batch = inc;

	storage::entry put1;
	fill_entry(put1, "k", "v1");
	cppcut_assert_equal(storage_rocksdb::apply_applied, s->apply_forwarded_change(epoch, inc, 10, put1, false));

	storage::entry del;
	del.key = "k";
	cppcut_assert_equal(storage_rocksdb::apply_applied, s->apply_forwarded_change(epoch, inc, 20, del, true));

	// The late copy of the ORIGINAL put arrives again (a retry of the
	// forwarded change, or the WAL copy of it).
	storage::entry late;
	fill_entry(late, "k", "v1");
	cppcut_assert_equal(storage_rocksdb::apply_skipped_superseded,
		s->apply_forwarded_change(epoch, inc, 10, late, false));

	string out;
	cut_assert_operator(storage_get_string(s, "k", out), !=, 0);   // still gone
	cut_assert_operator(s->get_repl_tombstones(), >, static_cast<uint64_t>(0));
	drop_rocksdb(s, wal_master_dir);
}

// Once the applied position has passed the delete, the tombstone may be
// collected — and an older put is then refused by the POSITION instead
// (design §3.5). This is the case a wall-clock window could not decide.
void test_apply_rule_old_put_refused_after_tombstone_collected() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc = s->get_incarnation();
	const string inc_for_batch = inc;

	storage::entry del;
	del.key = "k";
	cppcut_assert_equal(storage_rocksdb::apply_applied, s->apply_forwarded_change(epoch, inc, 20, del, true));
	cppcut_assert_equal(static_cast<uint64_t>(1), s->get_repl_tombstones());

	// Advance the applied position past the delete with an empty WAL batch,
	// which also runs the bounded collection.
	cut_assert_equal_int(0, s->set_repl_last_lsn(29));
	rocksdb::WriteBatch empty_batch;
	// A reserved key: numbered by the decoder, never applied as data (§3.6).
	empty_batch.Put(rocksdb::Slice(storage_rocksdb::kReplLastLsnKey), rocksdb::Slice("30"));
	uint64_t applied = 0, skipped = 0;
	storage_rocksdb::apply_outcome refusal;
	cut_assert_equal_int(0, s->apply_wal_batch(epoch, inc_for_batch, 30, empty_batch, applied, skipped, refusal));
	cut_assert_operator(s->get_repl_last_lsn(), >=, static_cast<uint64_t>(20));
	cppcut_assert_equal(static_cast<uint64_t>(0), s->get_repl_tombstones());   // collected

	storage::entry late;
	fill_entry(late, "k", "v1");
	cppcut_assert_equal(storage_rocksdb::apply_refused_cursor,
		s->apply_forwarded_change(epoch, inc, 10, late, false));
	string out;
	cut_assert_operator(storage_get_string(s, "k", out), !=, 0);   // still gone
	drop_rocksdb(s, wal_master_dir);
}

// A forwarded change never advances the replication position: it says nothing
// about what the WAL has delivered (design §3.4).
void test_apply_rule_forwarded_change_does_not_advance_cursor() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc = s->get_incarnation();
	const string inc_for_batch = inc;
	const uint64_t before = s->get_repl_last_lsn();

	storage::entry e;
	fill_entry(e, "k", "v");
	cppcut_assert_equal(storage_rocksdb::apply_applied, s->apply_forwarded_change(epoch, inc, 500, e, false));
	cppcut_assert_equal(before, s->get_repl_last_lsn());
	drop_rocksdb(s, wal_master_dir);
}

// A change from another history, or issued against a previous copy, is
// refused before anything is compared.
void test_apply_rule_refuses_foreign_session_and_stale_incarnation() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc = s->get_incarnation();
	const string inc_for_batch = inc;

	storage::entry e;
	fill_entry(e, "k", "v");
	cppcut_assert_equal(storage_rocksdb::apply_refused_session,
		s->apply_forwarded_change("9:not-our-history", inc, 10, e, false));
	cppcut_assert_equal(storage_rocksdb::apply_refused_incarnation,
		s->apply_forwarded_change(epoch, "9:not-our-copy", 10, e, false));

	string out;
	cut_assert_operator(storage_get_string(s, "k", out), !=, 0);   // nothing written
	drop_rocksdb(s, wal_master_dir);
}

// Within one WAL batch the same key may change twice; the later change must
// see the earlier one, and the result must equal applying them in order.
void test_apply_rule_intra_batch_same_key_twice() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc_for_batch = s->get_incarnation();

	storage_rocksdb* scratch = make_rocksdb(wal_slave_dir);
	const string v1 = serialized_entry(scratch, "k", "v1");
	const string v2 = serialized_entry(scratch, "k", "v2");
	rocksdb::WriteBatch batch;
	batch.Put(rocksdb::Slice("k"), rocksdb::Slice(v1));
	batch.Put(rocksdb::Slice("k"), rocksdb::Slice(v2));

	uint64_t applied = 0, skipped = 0;
	storage_rocksdb::apply_outcome refusal;
	cut_assert_equal_int(0, s->apply_wal_batch(epoch, inc_for_batch, 1, batch, applied, skipped, refusal));
	cppcut_assert_equal(static_cast<uint64_t>(2), applied);   // both, in order
	string out;
	cut_assert_equal_int(0, storage_get_string(s, "k", out));
	cut_assert_equal_string("v2", out.c_str());
	drop_rocksdb(scratch, wal_slave_dir);
	drop_rocksdb(s, wal_master_dir);
}

// A batch the decoder cannot number is refused in a RELEASE build, with
// nothing written and nothing skipped — never applied partially.
void test_apply_rule_refuses_undecodable_batch() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc_for_batch = s->get_incarnation();
	const uint64_t before_cursor = s->get_repl_last_lsn();

	rocksdb::WriteBatch batch;
	batch.Merge(rocksdb::Slice("k"), rocksdb::Slice("x"));   // not a flare operation
	uint64_t applied = 0, skipped = 0;
	storage_rocksdb::apply_outcome refusal;
	cut_assert_equal_int(-1, s->apply_wal_batch(epoch, inc_for_batch, 1, batch, applied, skipped, refusal));
	cppcut_assert_equal(storage_rocksdb::apply_error, refusal);
	cppcut_assert_equal(before_cursor, s->get_repl_last_lsn());
	cut_assert_operator(s->get_repl_decode_refused(), >, static_cast<uint64_t>(0));
	drop_rocksdb(s, wal_master_dir);
}

// A batch that does not continue the applied position is refused: advancing
// over a gap would record changes as applied that never were.
void test_apply_rule_refuses_gap_in_the_stream() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc_for_batch = s->get_incarnation();

	storage_rocksdb* scratch = make_rocksdb(wal_slave_dir);
	const string v = serialized_entry(scratch, "k", "v");
	rocksdb::WriteBatch batch;
	batch.Put(rocksdb::Slice("k"), rocksdb::Slice(v));

	uint64_t applied = 0, skipped = 0;
	storage_rocksdb::apply_outcome refusal;
	// The position is 0; a batch starting at 50 leaves 1..49 unaccounted.
	cut_assert_equal_int(-1, s->apply_wal_batch(epoch, inc_for_batch, 50, batch, applied, skipped, refusal));
	cppcut_assert_equal(static_cast<uint64_t>(0), s->get_repl_last_lsn());
	drop_rocksdb(scratch, wal_slave_dir);
	drop_rocksdb(s, wal_master_dir);
}

// The metadata family is per-copy: a restore must not inherit the source's
// rows, or labels from two histories would be compared.
void test_apply_rule_restore_clears_inherited_metadata() {
	storage_rocksdb* master = make_rocksdb(wal_master_dir);
	storage_rocksdb* slave  = make_rocksdb(wal_slave_dir);

	// Give the SLAVE some metadata of its own, then restore over it.
	const string sepoch = slave->get_source_epoch();
	const string sinc = slave->get_incarnation();
	storage::entry e;
	fill_entry(e, "own", "v");
	cppcut_assert_equal(storage_rocksdb::apply_applied, slave->apply_forwarded_change(sepoch, sinc, 5, e, false));
	storage::entry d;
	d.key = "own";
	cppcut_assert_equal(storage_rocksdb::apply_applied, slave->apply_forwarded_change(sepoch, sinc, 6, d, true));
	cut_assert_operator(slave->get_repl_tombstones(), >, static_cast<uint64_t>(0));

	cut_assert_equal_int(0, storage_set_string(master, "k", "v"));
	string cp_path;
	uint64_t cp_seq = 0;
	cut_assert_equal_int(0, master->create_snapshot_checkpoint(cp_path, cp_seq));
	string staging;
	cut_assert_equal_int(0, slave->prepare_snapshot_staging(staging));
	cut_assert_equal_int(0, copy_dir_flat(cp_path, staging));
	cut_assert_equal_int(0, master->remove_snapshot_checkpoint(cp_path));
	cut_assert_equal_int(0, slave->swap_in_snapshot(staging, cp_seq));

	cppcut_assert_equal(static_cast<uint64_t>(0), slave->get_repl_tombstones());
	drop_rocksdb(master, wal_master_dir);
	drop_rocksdb(slave,  wal_slave_dir);
}

// ---------------------------------------------------------------------------
// SAF-10b stage 2, review fixes: the generation check inside the section, the
// live-key count, metadata-only batches, and concurrent delivery.
// ---------------------------------------------------------------------------

namespace {
	// Count the keys actually present in the default family, excluding the
	// reserved replication keys — the independent truth curr_items must match.
	uint64_t real_key_count(storage_rocksdb* s) {
		uint64_t n = 0;
		storage::entry e;
		if (s->iter_begin() < 0) {
			return 0;
		}
		while (s->iter_next(e.key) == storage::iteration_continue) {
			n++;
		}
		s->iter_end();
		return n;
	}

	struct forward_worker_arg {
		storage_rocksdb* s;
		string epoch;
		string incarnation;
		int base_label;
		int count;
		int applied;
	};

	void* forward_worker(void* raw) {
		forward_worker_arg* a = static_cast<forward_worker_arg*>(raw);
		for (int i = 0; i < a->count; i++) {
			char k[32];
			snprintf(k, sizeof(k), "conc%03d", i);
			storage::entry e;
			e.key = k;
			e.size = 2;
			e.data = shared_byte(new uint8_t[2]);
			memcpy(e.data.get(), "vv", 2);
			e.flag = 0;
			e.expire = 0;
			e.version = 1;
			if (a->s->apply_forwarded_change(a->epoch, a->incarnation,
					static_cast<uint64_t>(a->base_label + i), e, false) == storage_rocksdb::apply_applied) {
				a->applied++;
			}
		}
		return NULL;
	}
}

// A WAL batch that carries ONLY metadata-family entries applies no data, but
// its entries are still numbered, so the position moves past them. If they
// were not counted, every later change in the stream would be mis-numbered.
void test_apply_rule_metadata_only_batch_advances_position() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc = s->get_incarnation();
	cut_assert_equal_int(0, s->set_repl_last_lsn(10));

	// Three entries in a family that is not the default one: exactly what a
	// source that applied deliveries has in its own WAL.
	rocksdb::WriteBatch batch;
	rocksdb::DB* raw = NULL;      // handles come from the storage's own DB
	(void)raw;
	rocksdb::ColumnFamilyHandle* meta = s->debug_meta_cf();
	cut_assert_not_null(meta);
	batch.Put(meta, rocksdb::Slice("a"), rocksdb::Slice("1:x|5|0"));
	batch.Put(meta, rocksdb::Slice("b"), rocksdb::Slice("1:x|6|0"));
	batch.Put(meta, rocksdb::Slice("c"), rocksdb::Slice("1:x|7|1"));

	uint64_t applied = 0, skipped = 0;
	storage_rocksdb::apply_outcome refusal;
	cut_assert_equal_int(0, s->apply_wal_batch(epoch, inc, 11, batch, applied, skipped, refusal));
	cppcut_assert_equal(static_cast<uint64_t>(0), applied);     // no data applied
	cppcut_assert_equal(static_cast<uint64_t>(0), skipped);
	// 11, 12, 13 were consumed by the three entries.
	cppcut_assert_equal(static_cast<uint64_t>(13), s->get_repl_last_lsn());
	cppcut_assert_equal(static_cast<uint64_t>(0), real_key_count(s));
	drop_rocksdb(s, wal_master_dir);
}

// An empty batch covers no sequence and must not move the position.
void test_apply_rule_empty_batch_does_not_move_position() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string inc = s->get_incarnation();
	cut_assert_equal_int(0, s->set_repl_last_lsn(10));

	rocksdb::WriteBatch empty;
	uint64_t applied = 0, skipped = 0;
	storage_rocksdb::apply_outcome refusal;
	cut_assert_equal_int(0, s->apply_wal_batch(epoch, inc, 11, empty, applied, skipped, refusal));
	cppcut_assert_equal(static_cast<uint64_t>(10), s->get_repl_last_lsn());
	drop_rocksdb(s, wal_master_dir);
}

// curr_items must equal the real key count after both paths have run,
// including a key created and deleted inside ONE batch and a key changed
// twice in one batch — the cases a per-change probe counts twice.
void test_apply_rule_curr_items_matches_real_key_count() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	storage_rocksdb* scratch = make_rocksdb(wal_slave_dir);
	const string epoch = s->get_source_epoch();
	const string inc = s->get_incarnation();

	// Forwarded: two creations, one overwrite, one delete.
	storage::entry a1; fill_entry(a1, "a", "1");
	cppcut_assert_equal(storage_rocksdb::apply_applied, s->apply_forwarded_change(epoch, inc, 1, a1, false));
	storage::entry b1; fill_entry(b1, "b", "1");
	cppcut_assert_equal(storage_rocksdb::apply_applied, s->apply_forwarded_change(epoch, inc, 2, b1, false));
	storage::entry a2; fill_entry(a2, "a", "2");
	cppcut_assert_equal(storage_rocksdb::apply_applied, s->apply_forwarded_change(epoch, inc, 3, a2, false));
	storage::entry bdel; bdel.key = "b";
	cppcut_assert_equal(storage_rocksdb::apply_applied, s->apply_forwarded_change(epoch, inc, 4, bdel, true));
	cut_assert_equal_int(static_cast<int>(real_key_count(s)), static_cast<int>(s->count()));

	// WAL: one key written twice in a single batch, and one created then
	// deleted in the same batch.
	const string cv1 = serialized_entry(scratch, "c", "1");
	const string cv2 = serialized_entry(scratch, "c", "2");
	const string dv1 = serialized_entry(scratch, "d", "1");
	rocksdb::WriteBatch batch;
	batch.Put(rocksdb::Slice("c"), rocksdb::Slice(cv1));
	batch.Put(rocksdb::Slice("c"), rocksdb::Slice(cv2));
	batch.Put(rocksdb::Slice("d"), rocksdb::Slice(dv1));
	batch.Delete(rocksdb::Slice("d"));

	uint64_t applied = 0, skipped = 0;
	storage_rocksdb::apply_outcome refusal;
	cut_assert_equal_int(0, s->apply_wal_batch(epoch, inc, 1, batch, applied, skipped, refusal));
	cppcut_assert_equal(static_cast<uint64_t>(4), applied);
	cut_assert_equal_int(static_cast<int>(real_key_count(s)), static_cast<int>(s->count()));
	cut_assert_equal_int(2, static_cast<int>(s->count()));   // a and c

	drop_rocksdb(scratch, wal_slave_dir);
	drop_rocksdb(s, wal_master_dir);
}

// A delivery for a PREVIOUS copy must be refused even when the copy is
// replaced after the delivery was issued: the check belongs inside the
// applying section, not before it.
void test_apply_rule_incarnation_checked_against_the_current_copy() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();
	const string stale_inc = s->get_incarnation();

	// The copy is replaced (a hard reset stands in for a snapshot restore).
	cut_assert_equal_int(0, s->hard_reset());
	const string fresh_inc = s->get_incarnation();
	cut_assert_not_equal_string(stale_inc.c_str(), fresh_inc.c_str());
	const string fresh_epoch = s->get_source_epoch();

	storage::entry e;
	fill_entry(e, "k", "v");
	cppcut_assert_equal(storage_rocksdb::apply_refused_incarnation,
		s->apply_forwarded_change(fresh_epoch, stale_inc, 100, e, false));

	rocksdb::WriteBatch batch;
	storage_rocksdb* scratch = make_rocksdb(wal_slave_dir);
	const string v = serialized_entry(scratch, "k", "v");
	batch.Put(rocksdb::Slice("k"), rocksdb::Slice(v));
	uint64_t applied = 0, skipped = 0;
	storage_rocksdb::apply_outcome refusal;
	cut_assert_equal_int(-1, s->apply_wal_batch(fresh_epoch, stale_inc, 1, batch, applied, skipped, refusal));
	cppcut_assert_equal(storage_rocksdb::apply_refused_incarnation, refusal);

	string out;
	cut_assert_operator(storage_get_string(s, "k", out), !=, 0);
	drop_rocksdb(scratch, wal_slave_dir);
	drop_rocksdb(s, wal_master_dir);
}

// Concurrency: forwarded changes from several threads while the WAL applier
// runs. The rule must hold under contention — no lost or double counting, no
// key left with an older value, and the position only moved by the applier.
void test_apply_rule_concurrent_forwarded_and_wal() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	storage_rocksdb* scratch = make_rocksdb(wal_slave_dir);
	const string epoch = s->get_source_epoch();
	const string inc = s->get_incarnation();
	cut_assert_equal_int(0, s->set_repl_last_lsn(1000));

	const int threads = 4;
	const int per_thread = 40;
	pthread_t tid[threads];
	forward_worker_arg args[threads];
	for (int t = 0; t < threads; t++) {
		args[t].s = s;
		args[t].epoch = epoch;
		args[t].incarnation = inc;
		// Every thread offers the SAME keys with different labels, so the
		// rule has to arbitrate: only the highest label may survive.
		args[t].base_label = 2000 + t * 1000;
		args[t].count = per_thread;
		args[t].applied = 0;
		cut_assert_equal_int(0, pthread_create(&tid[t], NULL, forward_worker, &args[t]));
	}

	// Meanwhile the applier delivers its own batches for other keys.
	for (int i = 0; i < 20; i++) {
		char k[32];
		snprintf(k, sizeof(k), "wal%03d", i);
		const string v = serialized_entry(scratch, k, "w");
		rocksdb::WriteBatch batch;
		batch.Put(rocksdb::Slice(k), rocksdb::Slice(v));
		uint64_t applied = 0, skipped = 0;
		storage_rocksdb::apply_outcome refusal;
		cut_assert_equal_int(0, s->apply_wal_batch(epoch, inc, 1001 + i, batch, applied, skipped, refusal));
	}

	for (int t = 0; t < threads; t++) {
		cut_assert_equal_int(0, pthread_join(tid[t], NULL));
	}

	// The count never drifted from the key space, whatever the interleaving.
	cut_assert_equal_int(static_cast<int>(real_key_count(s)), static_cast<int>(s->count()));
	cut_assert_equal_int(per_thread + 20, static_cast<int>(s->count()));
	// The position moved only by the applier's batches.
	cppcut_assert_equal(static_cast<uint64_t>(1020), s->get_repl_last_lsn());
	// Every contended key ends at the highest label offered for it.
	for (int i = 0; i < per_thread; i++) {
		char k[32];
		snprintf(k, sizeof(k), "conc%03d", i);
		storage::entry e;
		fill_entry(e, k, "older");
		cppcut_assert_equal(storage_rocksdb::apply_skipped_superseded,
			s->apply_forwarded_change(epoch, inc, static_cast<uint64_t>(2000 + (threads - 1) * 1000 + i), e, false));
	}

	drop_rocksdb(scratch, wal_slave_dir);
	drop_rocksdb(s, wal_master_dir);
}

// The wire-level entry point: a forwarded change that arrived with an
// identity is mapped onto the common rule, and each outcome is reported in
// the form the source needs — "skipped" must not look like a failure, or the
// source would count a drop and request a repair for nothing.
void test_identified_change_maps_outcomes_for_the_source() {
	storage_rocksdb* s = make_rocksdb(wal_master_dir);
	const string epoch = s->get_source_epoch();

	storage::entry e1;
	fill_entry(e1, "k", "v1");
	cut_assert_equal_int(storage::identified_applied,
		s->apply_identified_change(epoch + "/10", e1, false));

	// The same change again, and an older one: already superseded, which is
	// a success from the source's point of view.
	storage::entry e2;
	fill_entry(e2, "k", "v1");
	cut_assert_equal_int(storage::identified_skipped,
		s->apply_identified_change(epoch + "/10", e2, false));
	storage::entry e3;
	fill_entry(e3, "k", "old");
	cut_assert_equal_int(storage::identified_skipped,
		s->apply_identified_change(epoch + "/9", e3, false));

	// Another history: the source must hear about it.
	storage::entry e4;
	fill_entry(e4, "k", "foreign");
	cut_assert_equal_int(storage::identified_refused,
		s->apply_identified_change("9:another-history/11", e4, false));

	// Malformed tags are refused, never guessed.
	storage::entry e5;
	fill_entry(e5, "k", "bad");
	cut_assert_equal_int(storage::identified_refused, s->apply_identified_change("no-slash", e5, false));
	cut_assert_equal_int(storage::identified_refused, s->apply_identified_change(epoch + "/notanumber", e5, false));
	cut_assert_equal_int(storage::identified_refused, s->apply_identified_change(epoch + "/0", e5, false));

	string out;
	cut_assert_equal_int(0, storage_get_string(s, "k", out));
	cut_assert_equal_string("v1", out.c_str());

	// A delete through the same entry point leaves the tombstone that stops
	// an older put from resurrecting the key.
	storage::entry d;
	d.key = "k";
	cut_assert_equal_int(storage::identified_applied, s->apply_identified_change(epoch + "/20", d, true));
	storage::entry late;
	fill_entry(late, "k", "v1");
	cut_assert_equal_int(storage::identified_skipped, s->apply_identified_change(epoch + "/10", late, false));
	cut_assert_operator(storage_get_string(s, "k", out), !=, 0);

	drop_rocksdb(s, wal_master_dir);
}

// A backend without a replication identity reports "unsupported" so the
// caller keeps doing what it always did.
void test_identified_change_unsupported_on_a_plain_storage() {
	storage::entry e;
	fill_entry(e, "k", "v");
	// The base implementation is what a non-WAL backend inherits.
	storage* plain = new mock_storage("tmp_mock_storage", 8, 4);
	cut_assert_equal_int(storage::identified_unsupported, plain->apply_identified_change("1:x/5", e, false));
	delete plain;
}

// ---------------------------------------------------------------------------
// SAF-10b stage 3b: the follower's decision table.
//
// The rule that matters most for the requirement this work exists for: a lost
// connection must NEVER be a repair trigger. Only a position that can no
// longer be satisfied — purged history, another history, a position ahead of
// the source — hands the node to the rebuild path (design §5.4).
// ---------------------------------------------------------------------------

void test_follow_disconnect_is_not_a_rebuild() {
	// Transport failure, whatever the last client result was.
	cppcut_assert_equal(handler_wal_follower::attempt_disconnected,
		handler_wal_follower::classify(op_repl_sync_wal::client_success, false));
	cppcut_assert_equal(handler_wal_follower::attempt_disconnected,
		handler_wal_follower::classify(op_repl_sync_wal::client_protocol_error, false));
	// Even a result that WOULD mean rebuild is not acted on when we could not
	// talk to the source: we did not learn anything about our position.
	cppcut_assert_equal(handler_wal_follower::attempt_disconnected,
		handler_wal_follower::classify(op_repl_sync_wal::client_lsn_purged, false));
}

void test_follow_only_unsatisfiable_positions_rebuild() {
	cppcut_assert_equal(handler_wal_follower::attempt_needs_rebuild,
		handler_wal_follower::classify(op_repl_sync_wal::client_lsn_purged, true));
	cppcut_assert_equal(handler_wal_follower::attempt_needs_rebuild,
		handler_wal_follower::classify(op_repl_sync_wal::client_epoch_mismatch, true));
	cppcut_assert_equal(handler_wal_follower::attempt_needs_rebuild,
		handler_wal_follower::classify(op_repl_sync_wal::client_master_id_mismatch, true));
	cppcut_assert_equal(handler_wal_follower::attempt_needs_rebuild,
		handler_wal_follower::classify(op_repl_sync_wal::client_lsn_ahead, true));

	// A source that cannot identify its history, or does not speak the op, is
	// an error to retry — not a reason to throw this copy away.
	cppcut_assert_equal(handler_wal_follower::attempt_error,
		handler_wal_follower::classify(op_repl_sync_wal::client_no_epoch, true));
	cppcut_assert_equal(handler_wal_follower::attempt_error,
		handler_wal_follower::classify(op_repl_sync_wal::client_not_supported, true));
	cppcut_assert_equal(handler_wal_follower::attempt_error,
		handler_wal_follower::classify(op_repl_sync_wal::client_apply_error, true));

	cppcut_assert_equal(handler_wal_follower::attempt_progress,
		handler_wal_follower::classify(op_repl_sync_wal::client_success, true));
}

// Every non-success carries a reason the operator can read; success carries
// none, so a stale reason is never shown as current.
void test_follow_reasons_are_named() {
	cut_assert_equal_string("", handler_wal_follower::reason_for(op_repl_sync_wal::client_success));
	cut_assert_equal_string("lsn_purged", handler_wal_follower::reason_for(op_repl_sync_wal::client_lsn_purged));
	cut_assert_equal_string("epoch_mismatch", handler_wal_follower::reason_for(op_repl_sync_wal::client_epoch_mismatch));
	cut_assert_equal_string("source_has_no_epoch", handler_wal_follower::reason_for(op_repl_sync_wal::client_no_epoch));
}

// The record the operator reads: state, reason, position and — always — the
// time the source's position was observed.
void test_follow_record_carries_state_reason_and_observation_time() {
	stats_object->follow_set_source("10.0.0.1:12121", "3:abc");
	stats_object->follow_set_state(stats::follow_initial_sync, "");
	stats::follow_record r = stats_object->get_follow_record();
	cut_assert_equal_string("10.0.0.1:12121", r.source.c_str());
	cut_assert_equal_string("3:abc", r.source_epoch.c_str());
	cut_assert_equal_string("initial_sync", r.state.c_str());

	stats_object->follow_note_source_position(4242);
	stats_object->follow_note_progress(4200);
	r = stats_object->get_follow_record();
	cppcut_assert_equal(static_cast<uint64_t>(4242), r.source_lsn);
	cppcut_assert_equal(static_cast<uint64_t>(4200), r.applied_lsn);
	cut_assert_operator(static_cast<int>(r.source_lsn_observed_at), >, 0);
	cut_assert_operator(static_cast<int>(r.last_progress_at), >, 0);

	// A position that does not advance does not refresh the progress time.
	const time_t progressed_at = r.last_progress_at;
	stats_object->follow_note_progress(4100);
	r = stats_object->get_follow_record();
	cppcut_assert_equal(static_cast<uint64_t>(4200), r.applied_lsn);
	cppcut_assert_equal(progressed_at, r.last_progress_at);

	stats_object->follow_set_state(stats::follow_disconnected, "peer_unreachable");
	r = stats_object->get_follow_record();
	cut_assert_equal_string("disconnected", r.state.c_str());
	cut_assert_equal_string("peer_unreachable", r.last_reason.c_str());

	// Back to following clears the reason, so a stale one is never read as
	// the current condition.
	stats_object->follow_set_state(stats::follow_following, "");
	r = stats_object->get_follow_record();
	cut_assert_equal_string("following", r.state.c_str());
	cut_assert_equal_string("", r.last_reason.c_str());
	stats_object->follow_set_state(stats::follow_idle, "");
}

	void teardown()
	{
		delete rocksdb_tester;
		cut_remove_path(tmp_dir, NULL);
		// Clean up any leftover WAL replication test dirs in case a test
		// aborted before drop_rocksdb() was called.
		cut_remove_path(wal_master_dir, NULL);
		cut_remove_path(wal_slave_dir, NULL);
		delete stats_object;
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
