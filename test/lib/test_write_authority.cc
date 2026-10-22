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
		write_fence::set_entry_hook(expire_in_between);
		cut_assert_equal_string("SERVER_ERROR write authority lost before apply\r\n", run_set("k5").c_str());
		write_fence::set_entry_hook(NULL);
		cut_assert_false(stored("k5"));
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::in_flight());
	}

	// a routine renewal of the SAME authority between admission and apply is
	// not a reason to fail the request (P2)
	void test_same_authority_renewal_after_admission_is_acknowledged()
	{
		grant_now();
		write_fence::set_entry_hook(renew_in_between);
		cut_assert_equal_string("STORED\r\n", run_set("k6").c_str());
		write_fence::set_entry_hook(NULL);
		cut_assert_true(stored("k6"));
		cut_assert_equal_string("STORED\r\n", run_set("k7").c_str());
	}

	// P1 counterexample, same key K: term 1 "K=v1" admitted and paused; term
	// 2 installed; "K=v2" is acknowledged; the old request resumes. It
	// answers an error and K stays v2 (it neither writes nor forwards).
	static void install_term2_and_write_v2()
	{
		write_fence::set_entry_hook(NULL);
		std::string why;
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 2, 1), why));
		cut_assert_equal_string("STORED\r\n", run_set("K", "vals2").c_str());
	}

	void test_old_term_request_does_not_overwrite_the_new_term_value()
	{
		grant_now(1, 1);
		write_fence::set_entry_hook(install_term2_and_write_v2);
		cut_assert_equal_string("SERVER_ERROR write authority lost before apply\r\n", run_set("K", "vals1").c_str());
		write_fence::set_entry_hook(NULL);
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
		write_fence::set_entry_hook(revoke_in_between);
		cut_assert_equal_string("SERVER_ERROR write authority lost before apply\r\n", run_set("k8", "lost1").c_str());
		write_fence::set_entry_hook(NULL);
		cut_assert_equal_string("keep1", value_of("k8").c_str());
		grant_now(2, 1);
		write_fence::set_entry_hook(revoke_in_between);	// term 1 revoke: term 2 stays
		cut_assert_equal_string("STORED\r\n", run_set("k9", "keep2").c_str());
		write_fence::set_entry_hook(NULL);
		cut_assert_equal_string("keep2", value_of("k9").c_str());
	}

	void test_default_is_off_and_changes_nothing()
	{
		write_fence::reset_for_test();
		cut_assert_false(write_fence::authority_enabled());
		write_fence::entry e;
		cut_assert_false(e.fenced());
		cut_assert_true(e.ack_ok());
		cppcut_assert_equal(static_cast<uint64_t>(0), write_fence::authority_refused());
	}

	void test_no_grant_refuses_when_on()
	{
		write_fence::entry e;
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
			write_fence::entry e;
			cut_assert_false(e.fenced());
			cut_assert_true(e.ack_ok());
		}
		fake_ns += TTL - 1;
		{
			write_fence::entry e;
			cut_assert_false(e.fenced());
		}
		fake_ns += 1;		// the deadline
		write_fence::entry e;
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
			write_fence::entry e;
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
		write_fence::entry held;						// admitted under term 1
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
		write_fence::entry e;
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
			write_fence::entry e;
			cut_assert_true(e.fenced());
		}
		// a membership with no successor says solo: no deadline
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 2, true), why));
		fake_ns += 100000 * S;
		cut_assert_true(write_fence::authority_valid());
		write_fence::entry e;
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
			write_fence::entry e;
			cut_assert_true(e.ack_ok());
		}
		{
			// expired while the mutation waited
			write_fence::entry e;
			fake_ns += TTL;
			cut_assert_false(e.ack_ok());
		}
		cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 2), why));
		{
			// renewed (same term / generation) while the mutation waited:
			// still acknowledged within the OLD deadline
			write_fence::entry e;
			cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 2), why));
			cut_assert_true(e.ack_ok());
		}
		{
			// a new generation while it waited: refuse
			write_fence::entry e;
			cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 3), why));
			cut_assert_false(e.ack_ok());
		}
		{
			// revoked while it waited
			write_fence::entry e;
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
		write_fence::entry held;
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
		write_fence::entry fresh;				// admitted under the renewed grant
		cut_assert_true(fresh.ack_ok());
	}

	void test_renewal_pair_revoke_or_new_term_in_between_refuses()
	{
		std::string why;
		grant_now(1, 1);
		write_fence::entry a;
		fake_ns += 2 * S;
		grant_now(1, 1);
		cut_assert_true(write_fence::authority_revoke(0, 1, 1, why));
		cut_assert_false(a.apply_begin());
		cut_assert_false(a.ack_ok());
		grant_now(2, 1);
		write_fence::entry b;
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
		write_fence::entry held;
		cut_assert_true(held.ack_ok());
		write_fence::authority_set_clock(NULL);		// the real default clock ...
		write_fence::authority_set_gettime(junk_gettime);	// ... that cannot be read
		cut_assert_false(write_fence::authority_valid());
		cut_assert_false(held.ack_ok());
		cut_assert_false(held.apply_begin());
		{
			write_fence::entry e;
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
	// write lands after it took effect); a renewal does not wait
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
		write_fence::entry e;
		cut_assert_true(e.apply_begin());			// a storage write is in progress
		grant_now(1, 1);							// renewal: no wait, no exclusive lock
		revoke_done = 0;
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, revoker, NULL));
		usleep(100 * 1000);
		cppcut_assert_equal(0, static_cast<int>(revoke_done));	// the revoke waits for the write
		e.apply_end();
		pthread_join(t, NULL);
		cppcut_assert_equal(1, static_cast<int>(revoke_done));
		cut_assert_false(write_fence::authority_valid());
	}
}
