/**
 *	test_source_eligibility.cc
 *
 *	R3: the pure read-source decision (source_eligibility.h).
 */
#include <cppcutter.h>
#include <source_eligibility.h>

using namespace std;
using namespace gree::flare;

namespace test_source_eligibility {
	source_binding bound(source_binding::state st, const string& src, const string& id, const string& epoch) {
		source_binding b;
		b.st = st;
		b.source = src;
		b.master_id = id;
		b.source_epoch = epoch;
		return b;
	}

	source_probe probe(const string& id, const string& epoch, bool token = true) {
		source_probe p;
		p.complete = true;
		p.master_id = id;
		p.epoch_token = token;
		p.source_epoch = epoch;
		return p;
	}

	void test_no_validated_copy_is_never_made_eligible_here() {
		cut_assert_equal_int(decision_keep, decide_source(source_binding(), "m2", probe("L", "e1")));
		cut_assert_equal_int(decision_keep, decide_source(bound(source_binding::needs_rebuild, "m1", "L", "e1"), "m2", probe("L", "e1")));
	}

	void test_same_source_same_history_keeps() {
		cut_assert_equal_int(decision_keep, decide_source(bound(source_binding::eligible, "m1", "L", "e1"), "m1", probe("L", "e1")));
	}

	// the full-run case (CI 37451914041): the copy came from the old master;
	// the new master advanced its epoch at its promotion
	void test_new_master_with_another_history_needs_rebuild() {
		cut_assert_equal_int(decision_needs_rebuild, decide_source(bound(source_binding::revalidating, "m1", "L", "e1"), "m2", probe("L", "e2")));
	}

	void test_new_master_with_the_same_history_rebinds() {
		cut_assert_equal_int(decision_rebind, decide_source(bound(source_binding::revalidating, "m1", "L", "e1"), "m2", probe("L", "e1")));
	}

	// the same NAME with a new history (re-promotion, bulk rewrite, restart
	// with lost data) is caught by the periodic check of an eligible copy
	void test_same_name_new_history_needs_rebuild() {
		cut_assert_equal_int(decision_needs_rebuild, decide_source(bound(source_binding::eligible, "m1", "L", "e1"), "m1", probe("L", "e9")));
	}

	void test_other_lineage_needs_rebuild() {
		cut_assert_equal_int(decision_needs_rebuild, decide_source(bound(source_binding::revalidating, "m1", "L", "e1"), "m2", probe("OTHER", "e1")));
	}

	// Unknown never discards the copy, and never restores eligibility
	void test_unknown_waits_and_keeps_the_copy() {
		source_probe none;
		cut_assert_equal_int(decision_wait_unknown, decide_source(bound(source_binding::revalidating, "m1", "L", "e1"), "m2", none));
		cut_assert_equal_int(decision_wait_unknown, decide_source(bound(source_binding::revalidating, "m1", "L", "e1"), "", probe("L", "e1")));
		// an unobservable master of an ELIGIBLE copy for the same source is not a history change
		cut_assert_equal_int(decision_keep, decide_source(bound(source_binding::eligible, "m1", "L", "e1"), "m1", none));
		// but a different master that cannot be observed withdraws it
		cut_assert_equal_int(decision_wait_unknown, decide_source(bound(source_binding::eligible, "m1", "L", "e1"), "m2", none));
	}

	void test_peer_without_epoch_cannot_confirm_a_copy_with_one() {
		cut_assert_equal_int(decision_wait_unknown, decide_source(bound(source_binding::revalidating, "m1", "L", "e1"), "m2", probe("L", "", false)));
		cut_assert_equal_int(decision_wait_unknown, decide_source(bound(source_binding::revalidating, "m1", "L", "e1"), "m2", probe("L", "", true)));
	}

	// a backend without a lineage (tch): nothing to compare, follows the map
	void test_copy_without_lineage_follows_the_map() {
		source_probe none;
		cut_assert_equal_int(decision_rebind, decide_source(bound(source_binding::revalidating, "m1", "", ""), "m2", none));
		cut_assert_equal_int(decision_keep, decide_source(bound(source_binding::eligible, "m1", "", ""), "m1", none));
		cut_assert_equal_int(decision_wait_unknown, decide_source(bound(source_binding::revalidating, "m1", "", ""), "", none));
	}

	void test_legacy_copy_lineage_only() {
		cut_assert_equal_int(decision_rebind, decide_source(bound(source_binding::revalidating, "m1", "L", ""), "m2", probe("L", "", false)));
		// a legacy copy facing a peer that now has a history: cannot compare
		cut_assert_equal_int(decision_wait_unknown, decide_source(bound(source_binding::revalidating, "m1", "L", ""), "m2", probe("L", "e1")));
	}
}
