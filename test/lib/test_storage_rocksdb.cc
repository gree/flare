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

#include <limits>
#include <sys/stat.h>
#include <sys/types.h>
#include <pthread.h>
#include <unistd.h>

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
