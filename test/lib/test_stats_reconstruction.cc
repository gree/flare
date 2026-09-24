/**
 *	test_stats_reconstruction.cc
 *
 *	The reconstruction completion record must be bound to the HANDLER's id,
 *	not to whatever handler is current when a notification arrives.
 */
#include <cppcutter.h>
#include <stats.h>
#include <handler_wal_follower.h>

using namespace std;
using namespace gree::flare;

namespace test_stats_reconstruction {
	stats* st = NULL;

	void setup() { st = new stats(); }
	void teardown() { delete st; st = NULL; }

	void test_follow_backlog_does_not_poll_sleep_after_superseded_slice() {
		cut_assert_true(handler_wal_follower::retry_immediately(handler_wal_follower::attempt_idle, true));
		cut_assert_true(handler_wal_follower::retry_immediately(handler_wal_follower::attempt_progress, true));
		cut_assert_false(handler_wal_follower::retry_immediately(handler_wal_follower::attempt_idle, false));
		cut_assert_false(handler_wal_follower::retry_immediately(handler_wal_follower::attempt_error, true));
		cut_assert_false(handler_wal_follower::retry_immediately(handler_wal_follower::attempt_disconnected, true));
	}

	void test_local_read_guard_disconnect_lag_and_recovery() {
		stats::follow_record r = st->get_follow_record();
		r.enabled = true;
		r.source_epoch = "epoch";
		r.state = "following";
		r.source_lsn = 100;
		r.applied_lsn = 99;
		r.source_lsn_observed_at = 1000;
		cut_assert_false(stats::follow_allows_local_read(r, 1000));
		r.applied_lsn = 100;
		cut_assert_true(stats::follow_allows_local_read(r, 1000));
		cut_assert_false(stats::follow_allows_local_read(r, 1006));
		cut_assert_false(stats::follow_allows_local_read(r, 999));
		r.state = "disconnected";
		cut_assert_false(stats::follow_allows_local_read(r, 1000));
		r.state = "needs_rebuild";
		cut_assert_false(stats::follow_allows_local_read(r, 1000));
		r.state = "following";
		cut_assert_true(stats::follow_allows_local_read(r, 1000));
		r.enabled = false;
		cut_assert_true(stats::follow_allows_local_read(r, 1006));
	}

	void test_fresh_process_has_no_record() {
		stats::reconstruction_record r = st->get_reconstruction_record();
		cut_assert_equal_int(0, (int)r.current_id);
		cut_assert_equal_string("none", r.current_state.c_str());
		cut_assert_equal_int(0, (int)r.last_success_id);
		cut_assert_true(r.boot_id != 0);
	}

	void test_begin_allocates_increasing_ids_and_marks_running() {
		uint64_t a = st->reconstruction_begin();
		uint64_t b = st->reconstruction_begin();
		cut_assert_equal_int(1, (int)a);
		cut_assert_equal_int(2, (int)b);
		stats::reconstruction_record r = st->get_reconstruction_record();
		cut_assert_equal_int(2, (int)r.current_id);
		cut_assert_equal_string("running", r.current_state.c_str());
	}

	// The reviewer's sequence: A begins (#1), B begins (#2, running), A
	// succeeds. The record must NOT say "latest #2 succeeded".
	void test_older_handler_success_does_not_claim_the_newer_id() {
		uint64_t a = st->reconstruction_begin();
		uint64_t b = st->reconstruction_begin();
		st->reconstruction_succeeded_from(a, "master-a:12121");
		stats::reconstruction_record r = st->get_reconstruction_record();
		cut_assert_equal_int((int)b, (int)r.current_id);
		cut_assert_equal_string("running", r.current_state.c_str());   // B still running
		cut_assert_equal_int((int)a, (int)r.last_success_id);           // A's own id, not B's
		cut_assert_equal_string("master-a:12121", r.last_success_source.c_str());
		// Then B succeeds: now the latest is a success.
		st->reconstruction_succeeded_from(b, "master-b:12121");
		r = st->get_reconstruction_record();
		cut_assert_equal_string("succeeded", r.current_state.c_str());
		cut_assert_equal_int((int)b, (int)r.last_success_id);
		cut_assert_equal_string("master-b:12121", r.last_success_source.c_str());
	}

	void test_late_success_of_older_handler_does_not_regress_last_success() {
		uint64_t a = st->reconstruction_begin();
		uint64_t b = st->reconstruction_begin();
		st->reconstruction_succeeded_from(b, "master-b:12121");
		st->reconstruction_succeeded_from(a, "master-a:12121");          // arrives late
		stats::reconstruction_record r = st->get_reconstruction_record();
		cut_assert_equal_int((int)b, (int)r.last_success_id);
		cut_assert_equal_string("master-b:12121", r.last_success_source.c_str());
		cut_assert_equal_string("succeeded", r.current_state.c_str());
	}

	void test_older_handler_failure_does_not_change_current_state() {
		uint64_t a = st->reconstruction_begin();
		uint64_t b = st->reconstruction_begin();
		st->reconstruction_failed_final(a);
		stats::reconstruction_record r = st->get_reconstruction_record();
		cut_assert_equal_int((int)b, (int)r.current_id);
		cut_assert_equal_string("running", r.current_state.c_str());
	}

	void test_current_handler_failure_after_earlier_success() {
		uint64_t a = st->reconstruction_begin();
		st->reconstruction_succeeded_from(a, "m:1");
		uint64_t b = st->reconstruction_begin();
		st->reconstruction_failed_final(b);
		stats::reconstruction_record r = st->get_reconstruction_record();
		cut_assert_equal_string("failed", r.current_state.c_str());
		cut_assert_equal_int((int)a, (int)r.last_success_id);            // last success stays #1
		cut_assert_true(r.last_success_id != r.current_id);              // so a controller must NOT activate
	}

	void test_abort_only_for_current_handler() {
		uint64_t a = st->reconstruction_begin();
		uint64_t b = st->reconstruction_begin();
		st->reconstruction_aborted_by_shutdown(a);
		cut_assert_equal_string("running", st->get_reconstruction_record().current_state.c_str());
		st->reconstruction_aborted_by_shutdown(b);
		cut_assert_equal_string("aborted", st->get_reconstruction_record().current_state.c_str());
	}
}
