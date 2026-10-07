/**
 *	test_copy_switch.cc
 *
 *	The crash-recovery table of the copy switch (copy_switch.h, design §4.2):
 *	a crash before or after every rename and intent update.
 */
#include <cppcutter.h>
#include <copy_switch.h>
#include <copy_capacity.h>

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
}
