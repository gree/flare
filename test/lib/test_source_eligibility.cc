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

	// a replica that committed a continued history: its binding is moved to
	// E', and the successor that reports E' is the same history
	void test_continued_binding_keeps_against_successor_at_new_history() {
		cut_assert_equal_int(decision_keep, decide_source(bound(source_binding::eligible, "m2", "L2", "e3"), "m2", probe("L2", "e3")));
		cut_assert_equal_int(decision_rebind, decide_source(bound(source_binding::revalidating, "m1", "L2", "e3"), "m2", probe("L2", "e3")));
	}

	// the successor has not committed yet and still reports the history the
	// copy left: waits (keeps), no rebuild
	void test_continued_source_behind_is_not_a_rebuild() {
		source_probe p = probe("L2", "e2");
		p.continued_source_behind = true;
		cut_assert_equal_int(decision_keep, decide_source(bound(source_binding::eligible, "m2", "L2", "e3"), "m2", p));
		cut_assert_equal_int(decision_wait_unknown, decide_source(bound(source_binding::revalidating, "m1", "L2", "e3"), "m2", p));
	}

	// a copy that was NOT continued (flag unset) still rebuilds on a real
	// history difference
	void test_not_continued_copy_with_other_history_still_rebuilds() {
		cut_assert_equal_int(decision_needs_rebuild, decide_source(bound(source_binding::eligible, "m2", "L2", "e3"), "m2", probe("L2", "e2")));
		cut_assert_equal_int(decision_needs_rebuild, decide_source(bound(source_binding::revalidating, "m1", "L", "e1"), "m2", probe("L", "e2")));
	}

	// Decision table of the continued-copy exception. Binding: moved to the
	// committed history (L2, e3); the copy left (L1, e2). The expected
	// decision is computed from the intended cells only: keep is exactly
	// {continued, same source, eligible, probe = left epoch + left master_id}
	// for a master_id mismatch; every other cell is what it was before.
	void test_decision_table_continued_master_id_exception() {
		const char* ids[] = {"L2", "L1", "OTHER"};		// same / old (left) / unrelated
		const char* epochs[] = {"e2", "e3", "ex"};		// left / committed / other
		for (int continued = 0; continued < 2; continued++)
		for (int same = 0; same < 2; same++)
		for (int e = 0; e < 3; e++)
		for (int m = 0; m < 3; m++)
		for (int elig = 0; elig < 2; elig++) {
			source_binding b = bound(elig ? source_binding::eligible : source_binding::revalidating, "m2", "L2", "e3");
			const string current = same ? "m2" : "m9";
			source_probe p = probe(ids[m], epochs[e]);
			// what the storage reports for a copy that was continued: the
			// grace window is open, the left epoch / master_id are matched
			p.continued_source_behind = continued && e == 0;
			p.continued_left_master_id = continued && m == 1;
			source_decision expect;
			if (m != 0) {
				expect = (continued && same && elig && e == 0 && m == 1) ? decision_keep : decision_needs_rebuild;
			} else if (e == 1) {
				expect = (elig && same) ? decision_keep : decision_rebind;
			} else if (continued && e == 0) {
				expect = (elig && same) ? decision_keep : decision_wait_unknown;
			} else {
				expect = decision_needs_rebuild;
			}
			cut_assert_equal_int(expect, decide_source(b, current, p),
				cut_message("continued=%d same=%d epoch=%s id=%s eligible=%d", continued, same, epochs[e], ids[m], elig));
		}
	}

	// the flags alone are not enough: no epoch in the probe, or a copy
	// validated without an epoch, never gets the master_id exception
	void test_master_id_exception_needs_a_comparable_epoch() {
		source_probe p = probe("L1", "", true);
		p.continued_source_behind = true;
		p.continued_left_master_id = true;
		cut_assert_equal_int(decision_needs_rebuild, decide_source(bound(source_binding::eligible, "m2", "L2", "e3"), "m2", p));
		p = probe("L1", "e2", false);
		p.continued_source_behind = true;
		p.continued_left_master_id = true;
		cut_assert_equal_int(decision_needs_rebuild, decide_source(bound(source_binding::eligible, "m2", "L2", "e3"), "m2", p));
		p = probe("L1", "e2");
		p.continued_source_behind = true;
		p.continued_left_master_id = true;
		cut_assert_equal_int(decision_needs_rebuild, decide_source(bound(source_binding::eligible, "m2", "L2", ""), "m2", p));
		// a left master_id without the left epoch
		p = probe("L1", "e2");
		p.continued_left_master_id = true;
		cut_assert_equal_int(decision_needs_rebuild, decide_source(bound(source_binding::eligible, "m2", "L2", "e3"), "m2", p));
	}
}
