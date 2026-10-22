/**
 *	test_write_authority.cc
 *
 *	The write AUTHORITY of write_fence (src/lib/write_fence.h, docs/design-
 *	node-operations-2026-10-19.md §12.6): deterministic tests on an injected
 *	boottime clock. Default (engine off) behaviour is covered by
 *	test_write_fence.cc.
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"
#include "mock_cluster.h"
#include "mock_storage.h"

#include <app.h>
#include <write_fence.h>
#include <op_set.h>
#include <op_delete.h>
#include <time_watcher.h>
#include <pthread.h>
#include <unistd.h>

using namespace gree::flare;

namespace test_write_authority
{
	static uint64_t fake_ns = 0;
	static uint64_t fake_clock() { return fake_ns; }
	static const uint64_t S = 1000000000ULL;
	static const uint64_t TTL = 10 * S;		// a test parameter, not a default

	static write_fence::authority_grant grant(uint64_t nonce, uint64_t term = 1, uint64_t gen = 1, bool solo = false)
	{
		write_fence::authority_grant g;
		g.partition = 0;
		g.term = term;
		g.generation = gen;
		g.pod_uid = "uid-A";
		g.boot_id = "boot-1";
		g.copy_id = "copy-1";
		g.nonce = nonce;
		g.ttl_ns = TTL;
		g.solo = solo;
		return g;
	}

	// an entry admitted as the MASTER-WRITE of partition 0 (the engine's
	// admission is where an entry says what it is)
	struct mentry : public write_fence::entry {
		mentry() { this->admit_master(0); }
	};

	static void start_node()
	{
		write_fence::reset_for_test();
		fake_ns = 1000 * S;
		write_fence::authority_set_clock(fake_clock);
		write_fence::authority_set_identity(0, "uid-A", "boot-1", "copy-1");
		write_fence::authority_set_enabled(true);
	}

	TEST_OP_CLASS_BEGIN(op_set, NULL, NULL)
		test_op_set(shared_connection c, cluster* cl, storage* st) : op_set(c, cl, st) { }
		EXPOSE(op_set, _entry);
	TEST_OP_CLASS_END;
	TEST_OP_CLASS_BEGIN(op_delete, NULL, NULL)
		test_op_delete(shared_connection c, cluster* cl, storage* st) : op_delete(c, cl, st) { }
	TEST_OP_CLASS_END;

	static mock_cluster*	cl = NULL;
	static mock_storage*	st = NULL;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		time_watcher_object = new time_watcher();	// storage access is observed (not polling)
		start_node();
		// this node is the master of the (only) partition, over a real op
		// handler and a storage object
		cl = new mock_cluster("localhost", 12121);
		cluster::node master = cl->set_node("localhost", 12121, cluster::role_master, cluster::state_active, 0, 100);
		cl->set_partition(0, master);
		st = new mock_storage("", 0, 0);
		st->open();
	}

	void teardown()
	{
		write_fence::reset_for_test();
		delete st;
		delete cl;
		delete time_watcher_object;
		time_watcher_object = NULL;
		delete stats_object;
		st = NULL;
		cl = NULL;
	}

	static std::string run_set(const char* key, const char* value = "VALUE")
	{
		shared_connection c(new connection_sstream(std::string(" ") + key + " 0 0 5\r\n" + value + "\r\n"));
		test_op_set op(c, cl, st);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		op._run_server();
		return dynamic_cast<connection_sstream&>(*c).get_output();
	}

	static std::string run_delete(const char* key)
	{
		shared_connection c(new connection_sstream(std::string(" ") + key + "\r\n"));
		test_op_delete op(c, cl, st);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		op._run_server();
		return dynamic_cast<connection_sstream&>(*c).get_output();
	}

	static bool stored(const char* key)
	{
		storage::entry e;
		e.key = key;
		storage::result r;
		st->get(e, r);
		return r == storage::result_found;
	}

	static std::string value_of(const char* key)
	{
		storage::entry e;
		e.key = key;
		storage::result r;
		st->get(e, r);
		return r == storage::result_found ? std::string(reinterpret_cast<const char*>(e.data.get()), e.size) : std::string("<none>");
	}

	static void grant_now(uint64_t term = 1, uint64_t gen = 1)
	{
		std::string why;
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), term, gen), why));
	}

	// The first real mutation path: a client set / delete through the op
	// handler into storage, with the engine on (via the seam).
	void test_op_path_default_off_stores()
	{
		write_fence::reset_for_test();
		cut_assert_equal_string("STORED\r\n", run_set("k0").c_str());
		cut_assert_true(stored("k0"));
	}

	void test_op_path_stores_under_a_grant()
	{
		grant_now();
		cut_assert_equal_string("STORED\r\n", run_set("k1").c_str());
		cut_assert_true(stored("k1"));
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::authority_refused());
	}

	// a silent old master: the operator never answers again, clients still
	// reach it — after expiry it refuses and does not touch storage
	void test_silent_old_master_refuses_set_and_delete_after_expiry()
	{
		grant_now();
		cut_assert_equal_string("STORED\r\n", run_set("k2").c_str());
		fake_ns += TTL;
		cut_assert_equal_string("SERVER_ERROR no write authority\r\n", run_set("k3").c_str());
		cut_assert_false(stored("k3"));
		cut_assert_equal_string("SERVER_ERROR no write authority\r\n", run_delete("k2").c_str());
		cut_assert_true(stored("k2"));			// the delete did not reach storage
		cppcut_assert_equal(static_cast<uint64_t>(2), write_fence::authority_refused());
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::in_flight());
	}

	void test_op_path_refuses_after_revoke()
	{
		std::string why;
		grant_now();
		cut_assert_true(write_fence::authority_revoke(0, 1, 1, why));
		cut_assert_equal_string("SERVER_ERROR no write authority\r\n", run_set("k4").c_str());
		cut_assert_false(stored("k4"));
	}

	// The authority ended (its deadline passed) while the mutation waited
	// between admission and the apply: it must NOT write (P1: refusing only
	// the ACK would leave the old value in storage).
	static void expire_in_between() { fake_ns += TTL; }
	static void renew_in_between()
	{
		std::string why;
		write_fence::authority_apply_grant(grant(write_fence::authority_begin_request()), why);
	}

	void test_expired_after_admission_does_not_write()
	{
		grant_now();
		write_fence::set_admit_hook(expire_in_between);
		cut_assert_equal_string("SERVER_ERROR write authority lost before apply\r\n", run_set("k5").c_str());
		write_fence::set_admit_hook(NULL);
		cut_assert_false(stored("k5"));
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::in_flight());
	}

	// a routine renewal of the SAME authority between admission and apply is
	// not a reason to fail the request (P2)
	void test_same_authority_renewal_after_admission_is_acknowledged()
	{
		grant_now();
		write_fence::set_admit_hook(renew_in_between);
		cut_assert_equal_string("STORED\r\n", run_set("k6").c_str());
		write_fence::set_admit_hook(NULL);
		cut_assert_true(stored("k6"));
		cut_assert_equal_string("STORED\r\n", run_set("k7").c_str());
	}

	// P1 counterexample, same key K: term 1 "K=v1" admitted and paused; term
	// 2 installed; "K=v2" is acknowledged; the old request resumes. It
	// answers an error and K stays v2 (it neither writes nor forwards).
	static void install_term2_and_write_v2()
	{
		write_fence::set_admit_hook(NULL);
		std::string why;
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 2, 1), why));
		cut_assert_equal_string("STORED\r\n", run_set("K", "vals2").c_str());
	}

	void test_old_term_request_does_not_overwrite_the_new_term_value()
	{
		grant_now(1, 1);
		write_fence::set_admit_hook(install_term2_and_write_v2);
		cut_assert_equal_string("SERVER_ERROR write authority lost before apply\r\n", run_set("K", "vals1").c_str());
		write_fence::set_admit_hook(NULL);
		cut_assert_equal_string("vals2", value_of("K").c_str());
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::in_flight());
	}

	static void revoke_in_between()
	{
		std::string why;
		write_fence::authority_revoke(0, 1, 1, why);
	}

	void test_revoked_after_admission_does_not_write_or_delete()
	{
		grant_now();
		cut_assert_equal_string("STORED\r\n", run_set("k8", "keep1").c_str());
		write_fence::set_admit_hook(revoke_in_between);
		cut_assert_equal_string("SERVER_ERROR write authority lost before apply\r\n", run_set("k8", "lost1").c_str());
		write_fence::set_admit_hook(NULL);
		cut_assert_equal_string("keep1", value_of("k8").c_str());
		grant_now(2, 1);
		write_fence::set_admit_hook(revoke_in_between);	// term 1 revoke: term 2 stays
		cut_assert_equal_string("STORED\r\n", run_set("k9", "keep2").c_str());
		write_fence::set_admit_hook(NULL);
		cut_assert_equal_string("keep2", value_of("k9").c_str());
	}

	void test_default_is_off_and_changes_nothing()
	{
		write_fence::reset_for_test();
		cut_assert_false(write_fence::authority_enabled());
		mentry e;
		cut_assert_false(e.fenced());
		cut_assert_true(e.ack_ok());
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::authority_refused());
	}

	void test_no_grant_refuses_when_on()
	{
		mentry e;
		cut_assert_true(e.fenced());
		cut_assert_equal_string("no write authority", e.refusal());
		cppcut_assert_equal(static_cast<uint64_t>(1), write_fence::authority_refused());
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::in_flight());
	}

	void test_grant_admits_then_expiry_refuses()
	{
		std::string why;
		const uint64_t n = write_fence::authority_begin_request();
		cut_assert_true(write_fence::authority_apply_grant(grant(n), why));
		{
			mentry e;
			cut_assert_false(e.fenced());
			cut_assert_true(e.ack_ok());
		}
		fake_ns += TTL - 1;
		{
			mentry e;
			cut_assert_false(e.fenced());
		}
		fake_ns += 1;		// the deadline
		mentry e;
		cut_assert_true(e.fenced());
		cut_assert_equal_string("no write authority", e.refusal());
	}

	// the deadline runs from the request SEND point: a reply that arrives
	// late does not get the time it spent on the way
	void test_deadline_counts_from_request_send()
	{
		std::string why;
		const uint64_t n = write_fence::authority_begin_request();
		fake_ns += 6 * S;							// the reply is slow
		cut_assert_true(write_fence::authority_apply_grant(grant(n), why));
		fake_ns += 3 * S + S - 1;					// 10 s - 1 ns after the SEND
		cut_assert_true(write_fence::authority_valid());
		fake_ns += 1;
		cut_assert_false(write_fence::authority_valid());
	}

	void test_reply_arriving_after_expiry_is_refused()
	{
		std::string why;
		const uint64_t n = write_fence::authority_begin_request();
		fake_ns += TTL;
		cut_assert_false(write_fence::authority_apply_grant(grant(n), why));
		cut_assert_equal_string("expired before it arrived", why.c_str());
		cut_assert_false(write_fence::authority_valid());
	}

	void test_renewal_extends_from_its_own_send_point()
	{
		std::string why;
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request()), why));
		fake_ns += 8 * S;
		const uint64_t n2 = write_fence::authority_begin_request();
		fake_ns += 1 * S;							// reply arrives 1 s after the send
		cut_assert_true(write_fence::authority_apply_grant(grant(n2), why));
		fake_ns += 8 * S;							// 17 s since the first, 9 s since the renew send
		cut_assert_true(write_fence::authority_valid());
		fake_ns += 1 * S;							// 10 s since the renew send
		cut_assert_false(write_fence::authority_valid());
	}

	void test_revoke_refuses_and_wins_over_a_late_older_grant()
	{
		std::string why;
		const uint64_t n1 = write_fence::authority_begin_request();
		cut_assert_true(write_fence::authority_apply_grant(grant(n1, 1, 1), why));
		const uint64_t n2 = write_fence::authority_begin_request();		// in flight
		cut_assert_true(write_fence::authority_revoke(0, 1, 1, why));
		cut_assert_false(write_fence::authority_valid());
		{
			mentry e;
			cut_assert_true(e.fenced());
		}
		// the renewal that was sent before the revoke arrives after it
		cut_assert_false(write_fence::authority_apply_grant(grant(n2, 1, 1), why));
		// even with a fresh nonce, the revoked (term, generation) stays dead
		const uint64_t n3 = write_fence::authority_begin_request();
		cut_assert_false(write_fence::authority_apply_grant(grant(n3, 1, 1), why));
		cut_assert_equal_string("revoked", why.c_str());
		// a newer generation is a new decision and is accepted
		const uint64_t n4 = write_fence::authority_begin_request();
		cut_assert_true(write_fence::authority_apply_grant(grant(n4, 1, 2), why));
		cut_assert_true(write_fence::authority_valid());
	}

	void test_revoke_before_any_grant_blocks_the_older_one()
	{
		std::string why;
		const uint64_t n = write_fence::authority_begin_request();
		cut_assert_true(write_fence::authority_revoke(0, 2, 0, why));
		cut_assert_false(write_fence::authority_apply_grant(grant(n, 1, 5), why));
		cut_assert_false(write_fence::authority_valid());
	}

	// a request sent under term 1 is still in flight when term 2 arrives
	// (e.g. the node was paused); on resume its reply is refused, and a
	// mutation admitted under term 1 is not acknowledged under term 2
	void test_new_term_refuses_the_old_in_flight_request_and_ack()
	{
		std::string why;
		const uint64_t n1 = write_fence::authority_begin_request();
		cut_assert_true(write_fence::authority_apply_grant(grant(n1, 1, 1), why));
		mentry held;						// admitted under term 1
		cut_assert_false(held.fenced());
		const uint64_t n_old = write_fence::authority_begin_request();	// term-1 renewal, in flight
		const uint64_t n2 = write_fence::authority_begin_request();
		cut_assert_true(write_fence::authority_apply_grant(grant(n2, 2, 1), why));
		cut_assert_false(write_fence::authority_apply_grant(grant(n_old, 1, 1), why));
		cut_assert_false(held.ack_ok());				// not acknowledged under term 2
		cut_assert_true(write_fence::authority_valid());	// term 2 itself is fine
	}

	void test_older_generation_and_older_term_refused()
	{
		std::string why;
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 3, 4), why));
		cut_assert_false(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 2, 9), why));
		cut_assert_equal_string("older term or generation", why.c_str());
		cut_assert_false(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 3, 3), why));
		cut_assert_equal_string("older term or generation", why.c_str());
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 3, 5), why));
	}

	void test_delayed_old_nonce_reply_refused()
	{
		std::string why;
		const uint64_t n1 = write_fence::authority_begin_request();
		const uint64_t n2 = write_fence::authority_begin_request();
		cut_assert_true(write_fence::authority_apply_grant(grant(n2), why));
		cut_assert_false(write_fence::authority_apply_grant(grant(n1), why));	// the older request, late
		cut_assert_equal_string("unknown, old or duplicate request nonce", why.c_str());
		cut_assert_false(write_fence::authority_apply_grant(grant(n2), why));	// duplicate
		cut_assert_false(write_fence::authority_apply_grant(grant(999), why));	// never asked
	}

	void test_grant_bound_to_identity()
	{
		std::string why;
		write_fence::authority_grant g = grant(write_fence::authority_begin_request());
		g.pod_uid = "uid-B";
		cut_assert_false(write_fence::authority_apply_grant(g, why));
		g = grant(write_fence::authority_begin_request());
		g.boot_id = "boot-0";
		cut_assert_false(write_fence::authority_apply_grant(g, why));
		g = grant(write_fence::authority_begin_request());
		g.copy_id = "copy-0";
		cut_assert_false(write_fence::authority_apply_grant(g, why));
		g = grant(write_fence::authority_begin_request());
		g.partition = 1;
		cut_assert_false(write_fence::authority_apply_grant(g, why));
		cut_assert_false(write_fence::authority_valid());
	}

	// a restart is a new process: no authority, and the reply to a request
	// of the old boot is refused (different boot id, and no pending request)
	void test_restart_starts_without_authority()
	{
		std::string why;
		const uint64_t n = write_fence::authority_begin_request();
		cut_assert_true(write_fence::authority_apply_grant(grant(n), why));
		const uint64_t n_old = write_fence::authority_begin_request();
		cut_assert_true(write_fence::authority_valid());
		// new process: fresh statics, new boot id
		write_fence::reset_for_test();
		write_fence::authority_set_clock(fake_clock);
		write_fence::authority_set_identity(0, "uid-A", "boot-2", "copy-1");
		write_fence::authority_set_enabled(true);
		cut_assert_false(write_fence::authority_valid());
		mentry e;
		cut_assert_true(e.fenced());
		cut_assert_false(write_fence::authority_apply_grant(grant(n_old), why));	// old boot's reply
	}

	// solo needs the authoritative membership to say so; an operator that
	// merely stops answering is expiry
	void test_solo_only_with_explicit_no_successor_membership()
	{
		std::string why;
		// replicated membership, operator then silent: expiry
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 1, false), why));
		fake_ns += 1000 * S;
		cut_assert_false(write_fence::authority_valid());
		{
			mentry e;
			cut_assert_true(e.fenced());
		}
		// a membership with no successor says solo: no deadline
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 2, true), why));
		fake_ns += 100000 * S;
		cut_assert_true(write_fence::authority_valid());
		mentry e;
		cut_assert_false(e.fenced());
		cut_assert_true(e.ack_ok());
		// a later membership that adds a successor ends solo (and then expires)
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 3, false), why));
		cut_assert_false(e.ack_ok());
		fake_ns += TTL;
		cut_assert_false(write_fence::authority_valid());
	}

	void test_solo_cannot_be_flipped_within_one_generation()
	{
		std::string why;
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 1, false), why));
		cut_assert_false(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 1, true), why));
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 1, false), why));
	}

	void test_ack_binds_the_admission_grant()
	{
		std::string why;
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request()), why));
		{
			mentry e;
			cut_assert_true(e.ack_ok());
		}
		{
			// expired while the mutation waited
			mentry e;
			fake_ns += TTL;
			cut_assert_false(e.ack_ok());
		}
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 2), why));
		{
			// renewed (same term / generation) while the mutation waited:
			// still acknowledged within the OLD deadline
			mentry e;
			cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 2), why));
			cut_assert_true(e.ack_ok());
		}
		{
			// a new generation while it waited: refuse
			mentry e;
			cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 3), why));
			cut_assert_false(e.ack_ok());
		}
		{
			// revoked while it waited
			mentry e;
			cut_assert_true(write_fence::authority_revoke(0, 1, 3, why));
			cut_assert_false(e.ack_ok());
		}
	}

	// the renewal pair of repro/flare-wauth-renew-review.cc: admit at 0,
	// renew the SAME term/generation at +2 (TTL 10): the held entry still
	// completes before the OLD deadline, and is refused from the OLD
	// deadline on (never re-mapped to the new TTL, which ends at +12)
	void test_renewal_pair_old_deadline_holds()
	{
		std::string why;
		grant_now(1, 1);
		mentry held;
		cut_assert_false(held.fenced());
		cut_assert_true(held.ack_ok());
		fake_ns += 2 * S;
		grant_now(1, 1);						// renewal, deadline now +12
		cut_assert_true(write_fence::authority_valid());
		fake_ns += 7 * S;						// +9: before the old deadline
		cut_assert_true(held.apply_begin());
		held.apply_end();
		cut_assert_true(held.ack_ok());
		cut_assert_true(held.still_authorized());
		fake_ns += 1 * S;						// +10: the old deadline
		cut_assert_true(write_fence::authority_valid());	// the new grant lives on
		cut_assert_false(held.apply_begin());
		cut_assert_false(held.ack_ok());
		cut_assert_false(held.still_authorized());
		mentry fresh;				// admitted under the renewed grant
		cut_assert_true(fresh.ack_ok());
	}

	void test_renewal_pair_revoke_or_new_term_in_between_refuses()
	{
		std::string why;
		grant_now(1, 1);
		mentry a;
		fake_ns += 2 * S;
		grant_now(1, 1);
		cut_assert_true(write_fence::authority_revoke(0, 1, 1, why));
		cut_assert_false(a.apply_begin());
		cut_assert_false(a.ack_ok());
		grant_now(2, 1);
		mentry b;
		grant_now(2, 1);						// renewal of term 2: b is fine
		cut_assert_true(b.ack_ok());
		grant_now(3, 1);						// new term: b is not
		cut_assert_false(b.apply_begin());
		cut_assert_false(b.ack_ok());
	}

	// clock_gettime(CLOCK_BOOTTIME) fails: fail closed, no uninitialised time
	static int failing_gettime(clockid_t, struct timespec*) { return -1; }
	static int junk_gettime(clockid_t, struct timespec* ts)
	{
		ts->tv_sec = 5;		// a value written before returning an error
		ts->tv_nsec = 5;
		return -1;
	}

	void test_clock_failure_fails_closed()
	{
		std::string why;
		grant_now();
		mentry held;
		cut_assert_true(held.ack_ok());
		write_fence::authority_set_clock(NULL);		// the real default clock ...
		write_fence::authority_set_gettime(junk_gettime);	// ... that cannot be read
		cut_assert_false(write_fence::authority_valid());
		cut_assert_false(held.ack_ok());
		cut_assert_false(held.apply_begin());
		{
			mentry e;
			cut_assert_true(e.fenced());
		}
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::authority_begin_request());
		cut_assert_false(write_fence::authority_apply_grant(grant(0), why));
		write_fence::authority_set_gettime(failing_gettime);
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::authority_begin_request());
		// a solo grant has no deadline, but an unreadable clock still refuses
		write_fence::authority_set_gettime(NULL);
		write_fence::authority_set_clock(fake_clock);
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 5, true), why));
		write_fence::authority_set_clock(NULL);
		write_fence::authority_set_gettime(failing_gettime);
		cut_assert_false(write_fence::authority_valid());
		// the clock back: a grant is needed again only if it had expired
		write_fence::authority_set_gettime(NULL);
		write_fence::authority_set_clock(fake_clock);
		cut_assert_true(write_fence::authority_valid());
	}

	// a change of authority waits for a write in flight (so that no old
	// write lands after it took effect); a renewal does not wait.
	// Deterministic: the change counts itself in authority_drain_waits()
	// when it finds the apply section held, so the test waits for THAT
	// (never for a clock), and the section is still open while it does.
	static volatile int revoke_done = 0;
	static void* revoker(void*)
	{
		std::string why;
		write_fence::authority_revoke(0, 1, 1, why);
		revoke_done = 1;
		return NULL;
	}

	void test_change_of_authority_drains_writes_in_flight_but_renewal_does_not()
	{
		grant_now(1, 1);
		mentry e;
		cut_assert_true(e.apply_begin());			// a storage write is in progress
		const uint64_t waits0 = write_fence::authority_drain_waits();
		grant_now(1, 1);							// renewal: no wait, no exclusive lock
		cppcut_assert_equal(waits0, write_fence::authority_drain_waits());
		revoke_done = 0;
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, revoker, NULL));
		// barrier: the revoke is parked on the held apply section
		for (int i = 0; write_fence::authority_drain_waits() == waits0; i++) {
			cut_assert_true(i < 10 * 1000 * 1000);	// liveness bound only; never a pass condition
			sched_yield();
		}
		cppcut_assert_equal(0, static_cast<int>(revoke_done));	// it cannot finish while the section is open
		cut_assert_true(write_fence::authority_valid());
		e.apply_end();
		pthread_join(t, NULL);
		cppcut_assert_equal(1, static_cast<int>(revoke_done));
		cut_assert_false(write_fence::authority_valid());
	}

	// ---- role-aware, per partition ----

	static write_fence::authority_grant grant_p(uint32_t partition, uint64_t nonce, uint64_t term = 1, uint64_t gen = 1)
	{
		write_fence::authority_grant g = grant(nonce, term, gen);
		g.partition = partition;
		return g;
	}

	static void grant_p_now(uint32_t partition, uint64_t term = 1, uint64_t gen = 1)
	{
		std::string why;
		cut_assert_true(write_fence::authority_apply_grant(grant_p(partition, write_fence::authority_begin_request(partition), term, gen), why));
	}

	void test_partitions_are_independent()
	{
		write_fence::authority_set_identity(1, "uid-A", "boot-1", "copy-1");	// a second partition on this node
		grant_p_now(0);
		{
			write_fence::entry e;
			cut_assert_true(e.admit_master(0));
		}
		{
			write_fence::entry e;
			cut_assert_false(e.admit_master(1));		// the grant of partition 0 is not partition 1's
			cut_assert_equal_string("no write authority", e.refusal());
		}
		{
			write_fence::entry e;
			cut_assert_false(e.admit_master(7));		// a partition this node never heard of
		}
		{
			write_fence::entry e;
			cut_assert_false(e.admit_master(-1));		// partition unknown: fail closed
		}
		grant_p_now(1, 5, 1);
		cut_assert_true(write_fence::authority_valid(0));
		cut_assert_true(write_fence::authority_valid(1));
		std::string why;
		cut_assert_true(write_fence::authority_revoke(0, 1, 1, why));		// partition 0 only
		cut_assert_false(write_fence::authority_valid(0));
		cut_assert_true(write_fence::authority_valid(1));
		write_fence::entry e1;
		cut_assert_true(e1.admit_master(1));
		cut_assert_equal_string("1:5:1", e1.authority_tag().c_str());
		fake_ns += TTL;								// both lapse by themselves, each on its own deadline
		cut_assert_false(write_fence::authority_valid(1));
	}

	void test_a_grant_cannot_be_used_for_another_partition_and_nonces_are_per_partition()
	{
		write_fence::authority_set_identity(1, "uid-A", "boot-1", "copy-1");
		const uint64_t n0 = write_fence::authority_begin_request(0);
		std::string why;
		write_fence::authority_grant g = grant_p(1, n0);			// a request sent for partition 0, answered for 1
		cut_assert_false(write_fence::authority_apply_grant(g, why));
		cut_assert_equal_string("unknown, old or duplicate request nonce", why.c_str());
		cut_assert_true(write_fence::authority_apply_grant(grant_p(0, n0), why));
	}

	void test_the_tag_roundtrips_and_malformed_tags_are_refused()
	{
		uint32_t p = 0;
		uint64_t t = 0, g = 0;
		cut_assert_true(write_fence::authority_parse_tag("3:12:7", p, t, g));
		cppcut_assert_equal(static_cast<uint32_t>(3), p);
		cppcut_assert_equal(static_cast<uint64_t>(12), t);
		cppcut_assert_equal(static_cast<uint64_t>(7), g);
		const char* bad[] = { "", "1", "1:2", "1:2:", "1:2:3:4", "a:1:1", "-1:1:1", "1:-2:3", "1: 2:3", "1:2:3 ", "99999999999:1:1", NULL };
		for (int i = 0; bad[i] != NULL; i++) {
			cut_assert_false(write_fence::authority_parse_tag(bad[i], p, t, g));
		}
		grant_now(4, 2);
		cut_assert_equal_string("0:4:2", write_fence::authority_current_tag(0).c_str());
		cut_assert_equal_string("", write_fence::authority_current_tag(1).c_str());
		mentry m;
		cut_assert_equal_string("0:4:2", m.authority_tag().c_str());
	}

	void test_replica_apply_needs_no_master_grant_but_the_current_term()
	{
		// no grant at all: this node is a replica of partition 0
		cut_assert_false(write_fence::authority_valid(0));
		write_fence::authority_set_floor(0, 3, 1);
		{
			write_fence::entry e;
			cut_assert_true(e.admit_replica(0, "0:3:1"));	// the current term
			cut_assert_true(e.apply_begin());
			e.apply_end();
			cut_assert_true(e.ack_ok());
		}
		{
			write_fence::entry e;
			cut_assert_false(e.admit_replica(0, "0:2:9"));	// an older term
			cut_assert_equal_string("no write authority", e.refusal());
		}
		{
			write_fence::entry e;
			cut_assert_true(e.admit_replica(0, "0:3:0"));	// same term, another generation: fenced by TERM only (docs §13)
		}
		{
			write_fence::entry e;
			cut_assert_false(e.admit_replica(0, ""));		// carries no authority
		}
		{
			write_fence::entry e;
			cut_assert_false(e.admit_replica(0, "1:3:1"));	// for another partition
		}
		{
			write_fence::entry e;
			cut_assert_false(e.admit_replica(-1, "0:3:1"));
		}
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::in_flight());
		{
			write_fence::entry e;
			cut_assert_true(e.admit_replica(0, "0:4:1"));	// a newer term is accepted and raises the floor
		}
		uint64_t t = 0, g = 0;
		cut_assert_true(write_fence::authority_floor(0, t, g));
		cppcut_assert_equal(static_cast<uint64_t>(4), t);
		write_fence::entry old;
		cut_assert_false(old.admit_replica(0, "0:3:1"));	// the old term is refused from now on
	}

	void test_replica_change_admitted_under_an_old_term_does_not_apply_after_a_newer_one()
	{
		write_fence::authority_set_floor(0, 1, 1);
		write_fence::entry stale;
		cut_assert_true(stale.admit_replica(0, "0:1:1"));	// admitted, stopped before its write
		{
			write_fence::entry newer;
			cut_assert_true(newer.admit_replica(0, "0:2:1"));	// the new term's change goes through
			cut_assert_true(newer.apply_begin());
			newer.apply_end();
			cut_assert_true(newer.ack_ok());
		}
		cut_assert_false(stale.apply_begin());				// then it resumes: it must not write
		cut_assert_false(stale.ack_ok());
	}

	void test_a_node_with_a_master_grant_takes_no_replica_change_and_a_demoted_master_stops()
	{
		grant_now(2, 1);
		{
			write_fence::entry e;
			cut_assert_false(e.admit_replica(0, "0:2:1"));	// it is the master of the partition itself
		}
		mentry master;
		cut_assert_true(master.apply_begin());
		master.apply_end();
		// the operator tells it a newer authority exists: it is a replica now
		write_fence::authority_set_floor(0, 3, 1);
		cut_assert_false(write_fence::authority_valid(0));
		cut_assert_false(master.ack_ok());
		write_fence::entry again;
		cut_assert_false(again.admit_master(0));			// a master write on a replica of the partition: refused
		write_fence::entry rep;
		cut_assert_true(rep.admit_replica(0, "0:3:1"));	// but the new master's changes apply
		std::string why;
		cut_assert_false(write_fence::authority_apply_grant(grant_p(0, write_fence::authority_begin_request(0), 2, 1), why));
		cut_assert_equal_string("older term or generation", why.c_str());
	}

	void test_floor_never_lowers()
	{
		write_fence::authority_set_floor(0, 5, 2);
		write_fence::authority_set_floor(0, 4, 9);
		write_fence::authority_set_floor(0, 5, 1);
		uint64_t t = 0, g = 0;
		cut_assert_true(write_fence::authority_floor(0, t, g));
		cppcut_assert_equal(static_cast<uint64_t>(5), t);
		cppcut_assert_equal(static_cast<uint64_t>(2), g);
	}

	void test_an_entry_that_never_said_what_it_is_is_refused_when_the_engine_is_on()
	{
		grant_now();
		write_fence::entry anon;
		cut_assert_false(anon.fenced());				// the fence part is unchanged
		cut_assert_false(anon.apply_begin());
		cut_assert_false(anon.ack_ok());
	}

	// ---- through the real op handlers, as a replica ----

	static std::string run_set_as_replica(cluster* c2, const char* key, const char* value, const char* tag, storage* s = NULL)
	{
		std::string line = std::string(" ") + key + " 0 0 5" + (tag[0] ? std::string(" wa=") + tag : std::string()) + "\r\n" + value + "\r\n";
		shared_connection c(new connection_sstream(line));
		test_op_set op(c, c2, s != NULL ? s : st);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		op.set_proxy("localhost:12199");		// forwarded by the master
		op._run_server();
		return dynamic_cast<connection_sstream&>(*c).get_output();
	}

	static mock_cluster* make_replica_cluster()
	{
		mock_cluster* c2 = new mock_cluster("localhost", 12121);
		cluster::node master = c2->set_node("localhost", 12199, cluster::role_master, cluster::state_active, 0, 100);
		cluster::node self = c2->set_node("localhost", 12121, cluster::role_slave, cluster::state_active, 0, 100);
		cluster::node slaves[1] = { self };
		c2->set_partition(0, master, slaves, 1);
		c2->set_partition_member(0, "localhost", 12121);
		return c2;
	}

	void test_replica_apply_through_the_op_with_the_engine_on_and_no_master_grant()
	{
		mock_cluster* c2 = make_replica_cluster();
		cut_assert_false(write_fence::authority_valid(0));
		write_fence::authority_set_floor(0, 2, 1);
		cut_assert_equal_string("STORED\r\n", run_set_as_replica(c2, "r1", "vals1", "0:2:1").c_str());
		cut_assert_true(stored("r1"));
		cut_assert_equal_string("SERVER_ERROR no write authority\r\n", run_set_as_replica(c2, "r2", "vals2", "0:1:1").c_str());
		cut_assert_false(stored("r2"));								// an older term
		cut_assert_equal_string("SERVER_ERROR no write authority\r\n", run_set_as_replica(c2, "r3", "vals3", "").c_str());
		cut_assert_false(stored("r3"));								// carries none
		cut_assert_equal_string("STORED\r\n", run_set_as_replica(c2, "r4", "vals4", "0:3:1").c_str());
		cut_assert_true(stored("r4"));
		cut_assert_equal_string("SERVER_ERROR no write authority\r\n", run_set_as_replica(c2, "r5", "vals5", "0:2:1").c_str());
		cut_assert_false(stored("r5"));								// the floor moved up with term 3
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::in_flight());
		delete c2;
	}

	// ---- the identified forwarded change's early-return ACK ----

	class identified_storage : public mock_storage {
	public:
		identified_storage(): mock_storage("", 0, 0) { }
		virtual int apply_identified_change(const std::string& tag, entry& e, bool is_delete) {
			(void)tag; (void)is_delete;
			fake_ns += TTL;				// time passes during the apply: the master's grant ends
			result r;
			this->set(e, r, 0);
			return identified_applied;
		}
	};

	void test_identified_forwarded_change_is_not_acknowledged_after_the_authority_ended()
	{
		// the node is the master here and receives an identified change
		// (proxied marks of its own map): the early-return ACK must be tied
		// to the admitted authority like the others
		grant_now(1, 1);
		mock_cluster* c2 = new mock_cluster("localhost", 12121);
		cluster::node master = c2->set_node("localhost", 12121, cluster::role_master, cluster::state_active, 0, 100);
		c2->set_node("localhost", 12199, cluster::role_slave, cluster::state_active, 0, 100);
		c2->set_partition(0, master);
		identified_storage* ist = new identified_storage();
		ist->open();
		shared_connection c(new connection_sstream(" ik 0 0 5 rl=epoch/1\r\nvalue\r\n"));
		test_op_set op(c, c2, ist);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		op.set_proxy("localhost:12199");
		op._run_server();
		cut_assert_equal_string("SERVER_ERROR write authority lost before ack\r\n", dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		delete ist;
		delete c2;
	}

	void test_identified_forwarded_change_is_acknowledged_inside_the_authority()
	{
		grant_now(1, 1);
		class quick_storage : public mock_storage {
		public:
			quick_storage(): mock_storage("", 0, 0) { }
			virtual int apply_identified_change(const std::string&, entry& e, bool) {
				result r;
				this->set(e, r, 0);
				return identified_applied;
			}
		};
		mock_cluster* c2 = new mock_cluster("localhost", 12121);
		cluster::node master = c2->set_node("localhost", 12121, cluster::role_master, cluster::state_active, 0, 100);
		c2->set_node("localhost", 12199, cluster::role_slave, cluster::state_active, 0, 100);
		c2->set_partition(0, master);
		quick_storage* qst = new quick_storage();
		qst->open();
		shared_connection c(new connection_sstream(" ik 0 0 5 rl=epoch/1\r\nvalue\r\n"));
		test_op_set op(c, c2, qst);
		cut_assert_equal_int(0, op._parse_text_server_parameters());
		op.set_proxy("localhost:12199");
		op._run_server();
		cut_assert_equal_string("STORED\r\n", dynamic_cast<connection_sstream&>(*c).get_output().c_str());
		delete qst;
		delete c2;
	}

	// The real forward: a client set on the master applied under a grant leaves the op with the
	// authority token of that grant, and the request the proxy queue writes to a replica carries
	// it as `wa=p:term:gen`; the replica's op accepts exactly that line under its floor, and not
	// under a floor of a newer term (C', docs §13).
	void test_the_forward_carries_the_authority_token_to_the_replica()
	{
		grant_now(3, 2);
		std::string wire;
		{
			shared_connection c(new connection_sstream(" fwdkey 0 0 5\r\nVALUE\r\n"));
			test_op_set op(c, cl, st);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			op._run_server();
			cut_assert_equal_string("0:3:2", op._entry.auth_tag.c_str());
			shared_connection out(new connection_sstream(""));
			test_op_set fwd(out, cl, st);
			cut_assert_equal_int(0, fwd._run_client(op._entry));
			wire = dynamic_cast<connection_sstream&>(*out).get_output();
		}
		cut_assert_true(wire.find(" wa=0:3:2") != std::string::npos);
		cut_assert_equal_string("set fwdkey 0 0 5 wa=0:3:2\r\nVALUE\r\n", wire.c_str());
		// the same line, applied by a replica of partition 0 (no master grant, floor of term 3)
		write_fence::reset_for_test();
		write_fence::authority_set_clock(fake_clock);
		write_fence::authority_set_enabled(true);
		write_fence::authority_set_floor(0, 3, 0);
		{
			shared_connection c(new connection_sstream(" fwdkey 0 0 5 wa=0:3:2\r\nVALUE\r\n"));
			test_op_set op(c, cl, st);
			cut_assert_equal_int(0, op._parse_text_server_parameters());
			cut_assert_equal_string("0:3:2", op._entry.auth_tag.c_str());
		}
		write_fence::authority_set_floor(0, 4, 0);
		write_fence::entry stale;
		cut_assert_false(stale.admit_replica(0, "0:3:2"));
	}
}
