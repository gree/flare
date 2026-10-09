/**
 *	test_copy_protection.cc
 *
 *	R3-D: the protection rule evaluated right before a replica's copy is
 *	destroyed or replaced (copy_protection.h). Mirrors the operator's
 *	repairSourceVerdict, evaluated at the destructive moment.
 */
#include <cppcutter.h>
#include <copy_protection.h>

using namespace std;
using namespace gree::flare;

namespace test_copy_protection {
	copy_identity replica(uint64_t items, const string& lineage, const string& epoch,
			const string& from_lineage = "", const string& from_epoch = "") {
		copy_identity c;
		c.known = true;
		c.items = items;
		c.lineage = lineage;
		c.epoch = epoch;
		c.rebuilt_from_lineage = from_lineage;
		c.rebuilt_from_epoch = from_epoch;
		return c;
	}

	copy_identity source(uint64_t items, const string& lineage, const string& epoch, const string& reason) {
		copy_identity c;
		c.known = true;
		c.items = items;
		c.lineage = lineage;
		c.epoch = epoch;
		c.epoch_reason = reason;
		return c;
	}

	void test_empty_local_copy_has_nothing_to_protect() {
		string why;
		cut_assert_equal_int(gate_allow_nothing_to_protect,
			decide_copy_gate(replica(0, "L", "e1"), source(0, "OTHER", "e9", "promotion"), why));
	}

	void test_source_with_keys_proceeds() {
		string why;
		cut_assert_equal_int(gate_allow, decide_copy_gate(replica(400, "L", "e1"), source(3, "L", "e9", "promotion"), why));
	}

	// test 9 / H1: the source was promoted (new epoch) and is EMPTY; the
	// replica's copy and evidence belong to the earlier history
	void test_dangerous_empty_source_keeps_the_copy() {
		string why;
		cut_assert_equal_int(gate_refuse_unsafe,
			decide_copy_gate(replica(400, "L", "e1", "L", "e1"), source(0, "L", "e2", "promotion"), why));
	}

	// test 2: the replica was rebuilt by a full dump from exactly this
	// history; the master was deleted to empty afterwards
	void test_legitimate_empty_source_by_rebuild_evidence_proceeds() {
		string why;
		cut_assert_equal_int(gate_allow,
			decide_copy_gate(replica(400, "L", "own", "L", "e2"), source(0, "L", "e2", "promotion"), why));
	}

	void test_empty_source_in_the_same_history_proceeds() {
		string why;
		cut_assert_equal_int(gate_allow, decide_copy_gate(replica(400, "L", "e2"), source(0, "L", "e2", "promotion"), why));
	}

	void test_empty_source_after_a_bulk_rewrite_proceeds() {
		string why;
		cut_assert_equal_int(gate_allow, decide_copy_gate(replica(400, "L", "e1"), source(0, "L", "e3", "bulk"), why));
	}

	void test_empty_source_of_another_lineage_keeps_the_copy() {
		string why;
		cut_assert_equal_int(gate_refuse_unsafe, decide_copy_gate(replica(400, "L", "e1"), source(0, "OTHER", "e1", "bulk"), why));
		cut_assert_equal_int(gate_refuse_unsafe, decide_copy_gate(replica(400, "", "e1"), source(0, "L", "e1", "bulk"), why));
	}

	// Unknown at the boundary: keep the copy, wait
	void test_unknown_source_keeps_the_copy() {
		string why;
		copy_identity unknown;
		cut_assert_equal_int(gate_refuse_unknown, decide_copy_gate(replica(400, "L", "e1"), unknown, why));
	}

	// an unreadable (corrupt) local copy is not an empty one
	void test_unreadable_local_copy_is_protected() {
		string why;
		copy_identity local;
		local.known = false;
		local.items = 0;
		cut_assert_equal_int(gate_refuse_unsafe, decide_copy_gate(local, source(0, "L", "e2", "promotion"), why));
		copy_identity unknown;
		cut_assert_equal_int(gate_refuse_unknown, decide_copy_gate(local, unknown, why));
	}

	void test_allow_and_names() {
		cut_assert_true(copy_gate_allows(gate_allow));
		cut_assert_true(copy_gate_allows(gate_allow_nothing_to_protect));
		cut_assert_false(copy_gate_allows(gate_refuse_unknown));
		cut_assert_false(copy_gate_allows(gate_refuse_unsafe));
	}
}
