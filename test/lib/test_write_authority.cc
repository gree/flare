/**
 *	test_write_authority.cc
 *
 *	The write AUTHORITY of write_fence (src/lib/write_fence.h, docs/design-
 *	node-operations-2026-10-19.md §13): deterministic tests on an injected
 *	boottime clock. Default (engine off) behaviour is covered by
 *	test_write_fence.cc.
 */

#include <cppcutter.h>

#include <write_fence.h>

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

	void setup() { start_node(); }
	void teardown() { write_fence::reset_for_test(); }

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
			// renewed while the mutation waited: refuse, do not ack under the new grant
			write_fence::entry e;
			cut_assert_true(write_fence::authority_apply_grant(grant(write_fence::authority_begin_request(), 1, 2), why));
			cut_assert_false(e.ack_ok());
		}
		{
			// revoked while it waited
			write_fence::entry e;
			cut_assert_true(write_fence::authority_revoke(0, 1, 2, why));
			cut_assert_false(e.ack_ok());
		}
	}
}
