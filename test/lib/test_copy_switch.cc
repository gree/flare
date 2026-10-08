/**
 *	test_copy_switch.cc
 *
 *	The crash-recovery table of the copy switch (copy_switch.h, design §4.2):
 *	a crash before or after every rename and intent update.
 */
#include <cppcutter.h>
#include <copy_switch.h>
#include <copy_capacity.h>
#include <copy_switch_fs.h>

#include <cerrno>
#include <sys/stat.h>

using namespace std;
using namespace gree::flare;

namespace test_copy_switch {
	switch_intent intent() {
		switch_intent in;
		in.attempt = "a1";
		in.old_id = "OLD:3";
		in.new_id = "NEW:1";
		in.phase = "prepared";
		return in;
	}

	switch_observation obs(const string& live, const string& retained, const string& staging) {
		switch_observation o;
		o.live = live;
		o.retained = retained;
		o.staging = staging;
		return o;
	}

	// crash after the intent was written (PREPARED), before the first rename
	void test_before_first_rename_aborts() {
		string why;
		cut_assert_equal_int(recovery_abort_attempt, decide_switch_recovery(intent(), obs("OLD:3", "", "NEW:1"), why));
	}

	// the intent PHASE may be stale: the first rename happened, the intent
	// update did not — still decided from what exists
	void test_after_first_rename_rolls_back_whatever_the_phase_says() {
		string why;
		switch_intent in = intent();
		in.phase = "prepared";
		cut_assert_equal_int(recovery_rollback, decide_switch_recovery(in, obs("", "OLD:3", "NEW:1"), why));
		in.phase = "live_retained";
		cut_assert_equal_int(recovery_rollback, decide_switch_recovery(in, obs("", "OLD:3", "NEW:1"), why));
	}

	// the second rename happened (intent update before or after)
	void test_after_second_rename_rolls_forward() {
		string why;
		switch_intent in = intent();
		in.phase = "live_retained";
		cut_assert_equal_int(recovery_roll_forward, decide_switch_recovery(in, obs("NEW:1", "OLD:3", ""), why));
		in.phase = "opened";
		cut_assert_equal_int(recovery_roll_forward, decide_switch_recovery(in, obs("NEW:1", "OLD:3", ""), why));
	}

	// the staging copy was already gone before the intent (aborted attempt
	// whose staging was cleaned): still nothing switched
	void test_live_old_without_staging_aborts() {
		string why;
		cut_assert_equal_int(recovery_abort_attempt, decide_switch_recovery(intent(), obs("OLD:3", "", ""), why));
	}

	void test_missing_retained_stops() {
		string why;
		cut_assert_equal_int(recovery_stop, decide_switch_recovery(intent(), obs("NEW:1", "", ""), why));
	}

	void test_inconsistent_states_stop_and_touch_nothing() {
		string why;
		// nothing anywhere
		cut_assert_equal_int(recovery_stop, decide_switch_recovery(intent(), obs("", "", ""), why));
		// an unknown copy in live
		cut_assert_equal_int(recovery_stop, decide_switch_recovery(intent(), obs("OTHER:9", "OLD:3", ""), why));
		// unreadable COPY_ID
		cut_assert_equal_int(recovery_stop, decide_switch_recovery(intent(), obs("?", "OLD:3", "NEW:1"), why));
		// both moved but staging still present with the new id (duplicate)
		cut_assert_equal_int(recovery_stop, decide_switch_recovery(intent(), obs("NEW:1", "OLD:3", "NEW:1"), why));
		// live missing and the retained copy is not the old one
		cut_assert_equal_int(recovery_stop, decide_switch_recovery(intent(), obs("", "NEW:1", "NEW:1"), why));
	}

	void test_malformed_intent_stops() {
		string why;
		switch_intent in = intent();
		in.new_id = in.old_id;
		cut_assert_equal_int(recovery_stop, decide_switch_recovery(in, obs("OLD:3", "", "OLD:3"), why));
		in = intent();
		in.old_id = "";
		cut_assert_equal_int(recovery_stop, decide_switch_recovery(in, obs("", "", "NEW:1"), why));
	}

	// --- design §8: retained copies -----------------------------------------
	retained_record rec() {
		retained_record r;
		r.replaced_by = "NEW:1";
		r.master_id = "M";
		r.epoch = "E";
		return r;
	}

	void test_retained_record_parses_and_refuses_malformed() {
		retained_record r;
		cut_assert_true(parse_retained_record("NEW:1 M E", r));
		cut_assert_equal_string("NEW:1", r.replaced_by.c_str());
		cut_assert_equal_string("M", r.master_id.c_str());
		cut_assert_equal_string("E", r.epoch.c_str());
		cut_assert_false(parse_retained_record("NEW:1 M", r));
		cut_assert_false(parse_retained_record("NEW:1 M ", r));		// no epoch (legacy source): approval only
		cut_assert_false(parse_retained_record("", r));
	}

	void test_retained_deleted_only_when_all_four_hold() {
		string why;
		cut_assert_true(retained_deletable(true, rec(), "NEW:1", true, "M", "E", true, true, why));
		// 1. no record of a verified switch
		cut_assert_false(retained_deletable(false, rec(), "NEW:1", true, "M", "E", true, true, why));
		// 2. the live copy is another one, a later generation, or inconsistent
		cut_assert_false(retained_deletable(true, rec(), "OTHER:1", true, "M", "E", true, true, why));
		cut_assert_false(retained_deletable(true, rec(), "NEW:2", true, "M", "E", true, true, why));
		cut_assert_false(retained_deletable(true, rec(), "NEW:1", false, "M", "E", true, true, why));
		// 3. the binding is not eligible, or to another lineage / history
		cut_assert_false(retained_deletable(true, rec(), "NEW:1", true, "M", "E", false, true, why));
		cut_assert_false(retained_deletable(true, rec(), "NEW:1", true, "M2", "E", true, true, why));
		cut_assert_false(retained_deletable(true, rec(), "NEW:1", true, "M", "E2", true, true, why));
		// 4. not Active in its own map
		cut_assert_false(retained_deletable(true, rec(), "NEW:1", true, "M", "E", true, false, why));
	}

	// --- design §9: capacity ---------------------------------------------------
	void test_capacity_reserve_unset_stops() {
		uint64_t need = 0;
		string why;
		cut_assert_equal_int(capacity_reserve_unset, decide_rebuild_capacity(-1, true, 100, 1000000, need, why));
		cut_assert_false(capacity_watch_ok(-1, 1000000, why));
	}

	void test_capacity_unknowns_stop() {
		uint64_t need = 0;
		string why;
		cut_assert_equal_int(capacity_source_unknown, decide_rebuild_capacity(10, false, 0, 1000000, need, why));
		cut_assert_equal_int(capacity_space_unknown, decide_rebuild_capacity(10, true, 100, -1, need, why));
		cut_assert_false(capacity_watch_ok(10, -1, why));
	}

	void test_capacity_growth_plus_reserve_without_double_counting() {
		uint64_t need = 0;
		string why;
		// what is free already reflects every copy on disk: need = source + reserve
		cut_assert_equal_int(capacity_ok, decide_rebuild_capacity(50, true, 100, 150, need, why));
		cut_assert_equal_int(150, static_cast<int>(need));
		cut_assert_equal_int(capacity_insufficient, decide_rebuild_capacity(50, true, 100, 149, need, why));
		// reserve 0 is a SET value (allowed), not unset
		cut_assert_equal_int(capacity_ok, decide_rebuild_capacity(0, true, 100, 100, need, why));
	}

	void test_capacity_watch_stops_before_the_reserve() {
		string why;
		cut_assert_true(capacity_watch_ok(50, 50, why));
		cut_assert_false(capacity_watch_ok(50, 49, why));
	}

	// ─── review 2026-10-08 P1: a file that cannot be read is not "absent" ───

	const char kDir[] = "tmp_copy_switch_fs";

	bool exists(const string& p) {
		struct stat st;
		return ::stat(p.c_str(), &st) == 0;
	}

	// live already moved to retained-a1, the new copy still staged: the
	// window an unreadable intent must never be resolved as "no intent"
	void make_mid_switch() {
		cut_remove_path(kDir, NULL);
		::mkdir(kDir, 0700);
		::mkdir((string(kDir) + "/retained-a1").c_str(), 0700);
		::mkdir((string(kDir) + "/staging-a1").c_str(), 0700);
		copy_fs::write_file_durable(string(kDir) + "/retained-a1", copy_fs::kCopyIdFile, "OLD:3\n");
		copy_fs::write_file_durable(string(kDir) + "/staging-a1", copy_fs::kCopyIdFile, "NEW:1\n");
		switch_intent in = intent();
		in.phase = "live_retained";
		copy_fs::write_intent(kDir, in);
	}

	void assert_untouched() {
		cut_assert_false(exists(string(kDir) + "/flare.rocksdb"));
		cut_assert_true(exists(string(kDir) + "/retained-a1/COPY_ID"));
		cut_assert_true(exists(string(kDir) + "/staging-a1/COPY_ID"));
		cut_assert_true(exists(string(kDir) + "/" + copy_fs::kIntentFile));
	}

	void check_intent_error_stops(int err, bool partial) {
		make_mid_switch();
		copy_fs::set_read_fault_for_test(copy_fs::kIntentFile, err, partial);
		string report;
		cut_assert_equal_int(-1, copy_fs::recover(kDir, "flare.rocksdb", report));
		cut_assert_equal_int(-1, copy_fs::cleanup_staging(kDir));
		copy_fs::clear_read_faults_for_test();
		assert_untouched();
		cut_remove_path(kDir, NULL);
	}

	void test_unreadable_intent_eacces_stops_and_touches_nothing() { check_intent_error_stops(EACCES, false); }
	void test_unreadable_intent_eio_stops_and_touches_nothing() { check_intent_error_stops(EIO, false); }
	void test_intent_read_error_part_way_stops_and_touches_nothing() { check_intent_error_stops(EIO, true); }

	// ENOENT is absence: a first start, or an unfinished attempt whose intent
	// was never written — recovery passes and the staging copy goes
	void test_absent_intent_is_a_normal_start() {
		cut_remove_path(kDir, NULL);
		::mkdir(kDir, 0700);
		string report;
		cut_assert_equal_int(0, copy_fs::recover(kDir, "flare.rocksdb", report));
		::mkdir((string(kDir) + "/staging-a2").c_str(), 0700);
		cut_assert_equal_int(0, copy_fs::recover(kDir, "flare.rocksdb", report));
		cut_assert_equal_int(1, copy_fs::cleanup_staging(kDir));
		cut_assert_false(exists(string(kDir) + "/staging-a2"));
		cut_remove_path(kDir, NULL);
	}

	void test_read_small_file_status_absent_present_error_and_limit() {
		cut_remove_path(kDir, NULL);
		::mkdir(kDir, 0700);
		string out;
		cut_assert_equal_int(copy_fs::file_absent, copy_fs::read_small_file_status(string(kDir) + "/none", out));
		copy_fs::write_file_durable(kDir, "small", "abc\n");
		cut_assert_equal_int(copy_fs::file_present, copy_fs::read_small_file_status(string(kDir) + "/small", out));
		cut_assert_equal_string("abc", out.c_str());
		// larger than the limit: an error, never returned truncated
		copy_fs::write_file_durable(kDir, "big", string(copy_fs::kSmallFileLimit + 10, 'x'));
		cut_assert_equal_int(copy_fs::file_error, copy_fs::read_small_file_status(string(kDir) + "/big", out));
		cut_assert_equal_string("", out.c_str());
		// injected: open failure and a read error part-way
		copy_fs::set_read_fault_for_test("/small", EACCES);
		cut_assert_equal_int(copy_fs::file_error, copy_fs::read_small_file_status(string(kDir) + "/small", out));
		copy_fs::clear_read_faults_for_test();
		copy_fs::set_read_fault_for_test("/small", EIO, true);
		cut_assert_equal_int(copy_fs::file_error, copy_fs::read_small_file_status(string(kDir) + "/small", out));
		copy_fs::clear_read_faults_for_test();
		// stat: absent only on ENOENT
		cut_assert_equal_int(copy_fs::file_absent, copy_fs::stat_path_status(string(kDir) + "/none"));
		copy_fs::set_read_fault_for_test("/small", EIO);
		cut_assert_equal_int(copy_fs::file_error, copy_fs::stat_path_status(string(kDir) + "/small"));
		copy_fs::clear_read_faults_for_test();
		cut_remove_path(kDir, NULL);
	}
}
