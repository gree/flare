/**
 *	test_copy_switch.cc
 *
 *	The crash-recovery table of the copy switch (copy_switch.h, design §4.2):
 *	a crash before or after every rename and intent update.
 */
#include <cppcutter.h>
#include <copy_switch.h>

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
}
