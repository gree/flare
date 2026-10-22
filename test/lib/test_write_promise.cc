/**
 *	test_write_promise.cc
 *
 *	C' (design §13): the successor's promise, the promotion gate and the
 *	master's request round, deterministic on an injected boottime clock.
 *	Master = partition 0, replica = partition 1 of the same process (the
 *	engine keeps state per partition), so the two sides share one fake clock
 *	and "no interval with both" can be asserted over time.
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"
#include "mock_cluster.h"

#include <app.h>
#include <write_fence.h>
#include <write_promise.h>
#include <op_authority.h>
#include <handler_authority.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace gree::flare;

namespace test_write_promise
{
	static uint64_t fake_ns = 0;
	static uint64_t fake_clock() { return fake_ns; }
	static const uint64_t S = 1000000000ULL;
	// test parameters, not defaults
	static const uint64_t TTL_MS = 10000, RENEW_MS = 3000, MARGIN_MS = 2000, MAX_TTL_MS = 10000;
	TEST_OP_CLASS_BEGIN(op_authority)
	TEST_OP_CLASS_END;

	static bool slave_ok = true;
	static bool is_slave(int p) { return slave_ok && p == 1; }

	static void start()
	{
		write_fence::reset_for_test();
		write_promise::reset_for_test();
		fake_ns = 1000 * S;
		slave_ok = true;
		write_fence::authority_set_clock(fake_clock);
		std::string why;
		cut_assert_true(write_promise::configure(true, MARGIN_MS, MAX_TTL_MS, why));
		write_promise::set_role_probe(is_slave);
		write_fence::authority_set_floor(1, 1, 1);
	}

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		start();
	}
	void teardown()
	{
		write_fence::reset_for_test();
		write_promise::reset_for_test();
		delete stats_object;
		stats_object = NULL;
	}

	static std::vector<std::string> one() { return std::vector<std::string>(1, "r:12121"); }

	// one request round of the master: send point now, the reply arrives `delay_ns` later
	static bool round(uint64_t delay_ns, size_t promised = 1)
	{
		write_promise::members m;
		cut_assert_true(write_promise::get_members(0, m));
		const uint64_t nonce = write_promise::begin_round(m);
		fake_ns += delay_ns;
		std::string why;
		return write_promise::finish_round(m, nonce, promised, why);
	}

	void test_the_flag_needs_explicit_numbers()
	{
		std::string why;
		cut_assert_false(write_promise::configure(true, 0, 10, why));
		cut_assert_false(write_promise::configure(true, 10, 0, why));
		cut_assert_true(write_promise::configure(false, 0, 0, why));
		cut_assert_false(write_promise::enabled());
		cut_assert_false(write_fence::authority_enabled());
	}

	void test_off_nothing_is_promised_and_a_promotion_is_not_gated()
	{
		std::string why;
		cut_assert_true(write_promise::configure(false, 0, 0, why));
		cut_assert_false(write_promise::promise(1, 1, 1, 1000, why));
		cut_assert_true(write_promise::may_promote(1, why));
	}

	void test_a_promise_needs_the_floor_the_term_and_a_bounded_ttl()
	{
		std::string why;
		cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));
		cut_assert_false(write_promise::promise(1, 2, 1, TTL_MS, why));			// a term the operator did not give
		cut_assert_false(write_promise::promise(1, 0, 1, TTL_MS, why));
		cut_assert_true(write_promise::promise(1, 1, 0, TTL_MS, why));			// the generation is not part of the floor
		cut_assert_true(write_promise::promise(1, 1, 7, TTL_MS, why));
		cut_assert_false(write_promise::promise(1, 1, 1, MAX_TTL_MS + 1, why));	// above max-ttl
		cut_assert_false(write_promise::promise(1, 1, 1, 0, why));
		cut_assert_false(write_promise::promise(2, 1, 1, TTL_MS, why));			// no floor for partition 2
		slave_ok = false;
		cut_assert_false(write_promise::promise(1, 1, 1, TTL_MS, why));			// not a slave of it
	}

	void test_the_promise_end_is_receive_plus_ttl_plus_margin_and_never_shorter()
	{
		std::string why;
		cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));
		write_promise::status s = write_promise::get_status(1);
		cut_assert_true(s.have_promise);
		// the quiet time after the start is max-ttl + margin = 12 s; the promise end is 12 s too
		cppcut_assert_equal(static_cast<uint64_t>(12000), s.remaining_ms);
		fake_ns += 5 * S;
		cut_assert_true(write_promise::promise(1, 1, 1, 1000, why));			// a short one never shortens the end
		cppcut_assert_equal(static_cast<uint64_t>(7000), write_promise::get_status(1).remaining_ms);
	}

	void test_prepare_stops_the_promises_and_cancel_resumes_them()
	{
		std::string why;
		write_promise::status s;
		cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));
		cut_assert_true(write_promise::prepare(1, 7, 2, s, why));
		cppcut_assert_equal(static_cast<int>(write_promise::st_preparing), static_cast<int>(s.st));
		cut_assert_false(write_promise::promise(1, 1, 1, TTL_MS, why));			// new and renewed promises are refused
		cut_assert_true(write_promise::prepare(1, 7, 2, s, why));				// the same intent again: idempotent
		cut_assert_false(write_promise::prepare(1, 8, 2, s, why));				// another intent while preparing
		fake_ns += 3600 * S;													// a timer never resumes
		cut_assert_false(write_promise::promise(1, 1, 1, TTL_MS, why));
		cut_assert_false(write_promise::cancel(1, 8, s, why));					// not this intent
		cut_assert_true(write_promise::cancel(1, 7, s, why));
		cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));
	}

	void test_promotion_needs_commit_and_the_end_of_the_last_promise_on_its_own_clock()
	{
		std::string why;
		write_promise::status s;
		fake_ns += 100 * S;														// past the start quiet time
		cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));			// end = +12 s
		cut_assert_false(write_promise::may_promote(1, why));					// following: not promotable
		cut_assert_true(write_promise::prepare(1, 7, 2, s, why));
		cut_assert_false(write_promise::may_promote(1, why));					// prepared, not committed
		fake_ns += 20 * S;														// the promise is over, still not committed
		cut_assert_false(write_promise::may_promote(1, why));
		cut_assert_true(write_promise::commit(1, 7, s, why));
		cut_assert_true(s.promotable);
		cut_assert_false(write_promise::cancel(1, 7, s, why));					// terminal: no reversal
		cut_assert_true(write_promise::may_promote(1, why));
		cut_assert_true(write_promise::may_promote(1, why));					// idempotent once promoted
		write_promise::note_role(1, false);										// demoted: following again
		cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));
	}

	void test_a_commit_before_the_promise_ended_waits()
	{
		std::string why;
		write_promise::status s;
		fake_ns += 100 * S;
		cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));
		cut_assert_true(write_promise::prepare(1, 7, 2, s, why));
		cut_assert_true(write_promise::commit(1, 7, s, why));
		cut_assert_false(s.promotable);
		cppcut_assert_equal(static_cast<uint64_t>(12000), s.remaining_ms);
		cut_assert_false(write_promise::may_promote(1, why));
		fake_ns += 11999 * 1000000ULL;
		cut_assert_false(write_promise::may_promote(1, why));
		fake_ns += 1000000ULL;
		cut_assert_true(write_promise::may_promote(1, why));
	}

	void test_commit_needs_a_prepare_of_that_intent()
	{
		std::string why;
		write_promise::status s;
		cut_assert_false(write_promise::commit(1, 7, s, why));
		cut_assert_true(write_promise::prepare(1, 7, 2, s, why));
		cut_assert_false(write_promise::commit(1, 8, s, why));
	}

	void test_a_restarted_replica_forgets_its_promises_but_waits_the_quiet_time()
	{
		std::string why;
		write_promise::status s;
		fake_ns += 100 * S;
		cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));
		// restart: configure again at the current time; everything is forgotten
		cut_assert_true(write_promise::configure(true, MARGIN_MS, MAX_TTL_MS, why));
		write_fence::authority_set_floor(1, 1, 1);
		cut_assert_true(write_promise::prepare(1, 9, 2, s, why));
		cut_assert_true(write_promise::commit(1, 9, s, why));
		cut_assert_false(write_promise::may_promote(1, why));					// max-ttl + margin after its own start
		fake_ns += 12 * S;
		cut_assert_true(write_promise::may_promote(1, why));
	}

	void test_a_delayed_reply_does_not_extend_the_master_and_an_old_nonce_is_refused()
	{
		std::string why;
		cut_assert_true(write_promise::set_members(0, 1, 1, TTL_MS, RENEW_MS, one(), why));
		write_promise::members m;
		cut_assert_true(write_promise::get_members(0, m));
		const uint64_t n1 = write_promise::begin_round(m);
		const uint64_t send1 = fake_ns;
		fake_ns += 11 * S;															// the reply is later than ttl
		cut_assert_false(write_promise::finish_round(m, n1, 1, why));
		cut_assert_false(write_fence::authority_valid(0));
		const uint64_t n2 = write_promise::begin_round(m);
		fake_ns += 4 * S;															// a slow but timely reply
		cut_assert_true(write_promise::finish_round(m, n2, 1, why));
		uint64_t t, g, rem;
		bool solo;
		cut_assert_true(write_fence::authority_info(0, t, g, solo, rem));
		cppcut_assert_equal(static_cast<uint64_t>(6000), static_cast<uint64_t>(rem / 1000000ULL));		// send point + ttl, not receive + ttl
		cut_assert_false(write_promise::finish_round(m, n2, 1, why));				// a duplicate
		cut_assert_false(write_promise::finish_round(m, n1, 1, why));				// an old one
		(void) send1;
	}

	void test_every_successor_must_promise()
	{
		std::string why;
		std::vector<std::string> two;
		two.push_back("a:1");
		two.push_back("b:1");
		cut_assert_true(write_promise::set_members(0, 1, 1, TTL_MS, RENEW_MS, two, why));
		cut_assert_false(round(0, 1));												// one of two: no grant
		cut_assert_false(write_fence::authority_valid(0));
		cut_assert_true(round(0, 2));
		cut_assert_true(write_fence::authority_valid(0));
	}

	void test_membership_never_goes_back_and_a_generation_is_not_reused()
	{
		std::string why;
		cut_assert_true(write_promise::set_members(0, 2, 3, TTL_MS, RENEW_MS, one(), why));
		cut_assert_false(write_promise::set_members(0, 2, 2, TTL_MS, RENEW_MS, one(), why));
		cut_assert_false(write_promise::set_members(0, 1, 9, TTL_MS, RENEW_MS, one(), why));
		cut_assert_true(write_promise::set_members(0, 2, 3, TTL_MS, RENEW_MS, one(), why));		// the same again
		std::vector<std::string> other(1, "x:1");
		cut_assert_false(write_promise::set_members(0, 2, 3, TTL_MS, RENEW_MS, other, why));	// another set, same generation
		cut_assert_false(write_promise::set_solo(0, 2, 3, why));								// another mode, same generation
		cut_assert_true(write_promise::set_solo(0, 2, 4, why));
		cut_assert_false(write_promise::set_members(0, 2, 3, TTL_MS, RENEW_MS, one(), why));
	}

	void test_a_solo_master_keeps_serving_and_leaving_solo_ends_the_unlimited_grant()
	{
		std::string why;
		cut_assert_true(write_promise::set_solo(0, 1, 1, why));
		cut_assert_true(write_fence::authority_valid(0));
		fake_ns += 100000 * S;														// operator absent for a long time
		cut_assert_true(write_fence::authority_valid(0));
		{
			write_fence::entry e;
			cut_assert_true(e.admit_master(0));
		}
		// the operator gives a successor: the old unlimited grant must not outlive it
		cut_assert_true(write_promise::set_members(0, 1, 2, TTL_MS, RENEW_MS, one(), why));
		cut_assert_false(write_fence::authority_valid(0));
		cut_assert_true(round(0));
		cut_assert_true(write_fence::authority_valid(0));
	}

	void test_the_master_stops_before_the_successor_may_be_promoted_over_time()
	{
		std::string why;
		write_promise::status s;
		cut_assert_true(write_promise::set_members(0, 1, 1, TTL_MS, RENEW_MS, one(), why));
		fake_ns += 100 * S;
		// the master sends at q; the replica receives 1 s later and records its end
		const uint64_t q = fake_ns;
		write_promise::members m;
		cut_assert_true(write_promise::get_members(0, m));
		const uint64_t nonce = write_promise::begin_round(m);
		fake_ns += 1 * S;
		cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));
		cut_assert_true(write_promise::finish_round(m, nonce, 1, why));
		// the operator cannot reach the master; it prepares and commits at the replica at q + 2 s
		fake_ns += 1 * S;
		cut_assert_true(write_promise::prepare(1, 5, 2, s, why));
		cut_assert_true(write_promise::commit(1, 5, s, why));
		// walk time in 100 ms steps: the master's authority and the successor's permission never overlap
		bool master_was_valid = false, replica_was_ok = false;
		for (uint64_t t = q + 2 * S; t < q + 30 * S; t += S / 10) {
			fake_ns = t;
			const bool master = write_fence::authority_valid(0);
			std::string w;
			const bool replica = write_promise::get_status(1).promotable;
			cut_assert_false(master && replica);
			master_was_valid = master_was_valid || master;
			replica_was_ok = replica_was_ok || replica;
		}
		cut_assert_true(master_was_valid);
		cut_assert_true(replica_was_ok);												// and it does become promotable: availability
		cut_assert_false(write_fence::authority_valid(0));
	}

	void test_without_a_prepare_a_silent_operator_changes_nothing()
	{
		std::string why;
		cut_assert_true(write_promise::set_members(0, 1, 1, TTL_MS, RENEW_MS, one(), why));
		for (int i = 0; i < 20; i++) {												// the operator is gone; M and R keep talking
			write_promise::members m;
			cut_assert_true(write_promise::get_members(0, m));
			const uint64_t nonce = write_promise::begin_round(m);
			cut_assert_true(write_promise::promise(1, 1, 1, TTL_MS, why));
			cut_assert_true(write_promise::finish_round(m, nonce, 1, why));
			cut_assert_true(write_fence::authority_valid(0));
			cut_assert_false(write_promise::get_status(1).promotable);
			fake_ns += RENEW_MS * 1000000ULL;
		}
		write_fence::entry e;
		cut_assert_true(e.admit_master(0));
	}

	void test_a_generation_change_does_not_refuse_the_masters_forwards()
	{
		// the operator gives the floor by TERM (generation 0); the master's tokens carry its own
		// generation, which moves with the successor set. Neither the forward of an older
		// generation of the same term nor one of a newer generation may be refused.
		write_fence::authority_set_floor(4, 2, 0);
		{
			write_fence::entry e;
			cut_assert_true(e.admit_replica(4, "4:2:1"));
		}
		{
			write_fence::entry e;
			cut_assert_true(e.admit_replica(4, "4:2:7"));
		}
		{
			write_fence::entry e;
			cut_assert_false(e.admit_replica(4, "4:1:9"));						// an older TERM is refused
		}
		{
			write_fence::entry e;
			cut_assert_true(e.admit_replica(4, "4:2:1"));						// and a LATE forward of an older generation is applied
		}
	}

	void test_a_demoted_master_loses_its_membership_and_its_grant()
	{
		std::string why;
		cut_assert_true(write_promise::set_solo(0, 1, 1, why));
		cut_assert_true(write_fence::authority_valid(0));
		write_promise::note_role(0, true);										// still the master: nothing happens
		cut_assert_true(write_fence::authority_valid(0));
		write_promise::note_role(0, false);										// the map took the role away
		cut_assert_false(write_fence::authority_valid(0));
		write_promise::members m;
		cut_assert_false(write_promise::get_members(0, m));
		cut_assert_true(write_promise::set_solo(0, 2, 1, why));					// a later term can master it again
		cut_assert_true(write_fence::authority_valid(0));
	}

	void test_a_replica_without_a_floor_refuses_changes()
	{
		write_fence::entry e;
		cut_assert_false(e.admit_replica(3, "3:1:1"));								// partition 3 has no floor
		write_fence::authority_set_floor(3, 1, 1);
		write_fence::entry f;
		cut_assert_true(f.admit_replica(3, "3:1:1"));
	}

	static std::string run_op(const std::string& line, int& parse_rc)
	{
		shared_connection c(new connection_sstream(line));
		test_op_authority op(c);
		parse_rc = op._parse_text_server_parameters();
		if (parse_rc == 0) {
			op._run_server();
		}
		return dynamic_cast<connection_sstream&>(*c).get_output();
	}

	static bool has(const std::string& out, const char* needle)
	{
		return out.find(needle) != std::string::npos;
	}

	void test_the_op_parses_every_verb_and_refuses_junk()
	{
		int rc = 0;
		const char* bad[] = { " bogus\r\n", " promise 1 1 1 1000\r\n", " promise 1 1 1 1000 5 6\r\n", " promise a 1 1 1000 5\r\n",
			" members 0 1 1 10000 3000\r\n", " solo 0 1\r\n", " prepare 1 7\r\n", " commit 1\r\n", " status\r\n", " status 1 2\r\n",
			" floor 0 1 -1\r\n", " \r\n", NULL };
		for (int i = 0; bad[i] != NULL; i++) {
			run_op(bad[i], rc);
			cppcut_assert_equal(-1, rc);
		}
	}

	void test_the_op_promise_replies_promised_or_an_error()
	{
		int rc = 0;
		std::string out = run_op(" promise 1 1 1 10000 55\r\n", rc);
		cppcut_assert_equal(0, rc);
		cut_assert_equal_string("PROMISED 55\r\n", out.c_str());
		cut_assert_true(write_promise::get_status(1).have_promise);
		out = run_op(" promise 1 9 1 10000 56\r\n", rc);						// not the term the operator gave
		cut_assert_equal_string("SERVER_ERROR term does not match the floor\r\n", out.c_str());
		out = run_op(" prepare 1 7 2\r\n", rc);
		cut_assert_true(has(out, "STAT promise_state preparing"));
		out = run_op(" promise 1 1 1 10000 57\r\n", rc);
		cut_assert_true(has(out, "SERVER_ERROR not following"));
	}

	void test_the_op_drives_prepare_commit_cancel_and_reports_status()
	{
		int rc = 0;
		std::string out = run_op(" floor 1 1 1\r\n", rc);
		cut_assert_true(has(out, "STAT floor_term 1"));
		out = run_op(" prepare 1 7 2\r\n", rc);
		cut_assert_true(has(out, "STAT promise_state preparing"));
		cut_assert_true(has(out, "STAT promise_intent 7"));
		cut_assert_true(has(out, "END\r\n"));
		out = run_op(" cancel 1 8\r\n", rc);
		cut_assert_true(has(out, "SERVER_ERROR"));
		out = run_op(" commit 1 7\r\n", rc);
		cut_assert_true(has(out, "STAT promise_state committed"));
		out = run_op(" cancel 1 7\r\n", rc);
		cut_assert_true(has(out, "SERVER_ERROR"));							// terminal
		out = run_op(" status 1\r\n", rc);
		cut_assert_true(has(out, "STAT promise_state committed"));
	}

	void test_the_op_sets_members_and_solo()
	{
		int rc = 0;
		std::string out = run_op(" members 0 1 1 10000 3000 a:1 b:1\r\n", rc);
		cut_assert_true(has(out, "STAT members_mode replicated"));
		cut_assert_true(has(out, "STAT members_successors a:1,b:1"));
		cut_assert_true(has(out, "STAT grant_valid 0"));
		out = run_op(" solo 0 1 2\r\n", rc);
		cut_assert_true(has(out, "STAT members_mode solo"));
		cut_assert_true(has(out, "STAT grant_valid 1"));
		cut_assert_true(has(out, "STAT grant_solo 1"));
		out = run_op(" members 0 1 1 10000 3000 a:1\r\n", rc);				// an older generation
		cut_assert_true(has(out, "SERVER_ERROR older term / generation"));
	}

	// a tiny listener standing for the replica's flared: it answers `authority promise`
	static int srv_fd = -1;
	static int srv_port = 0;
	static volatile bool srv_stop = false;
	static pthread_t srv_th;

	static void* srv_main(void*)
	{
		while (!srv_stop) {
			struct pollfd pf;
			pf.fd = srv_fd;
			pf.events = POLLIN;
			if (poll(&pf, 1, 50) <= 0) {
				continue;
			}
			const int fd = accept(srv_fd, NULL, NULL);
			if (fd < 0) {
				continue;
			}
			char buf[256];
			size_t n = 0;
			while (n + 1 < sizeof(buf)) {
				if (read(fd, buf + n, 1) != 1) {
					break;
				}
				if (buf[n++] == '\n') {
					break;
				}
			}
			buf[n] = '\0';
			unsigned p = 0;
			(void) p;
			unsigned long long term = 0, gen = 0, ttl = 0, nonce = 0;
			char reply[160];
			std::string why;
			if (sscanf(buf, "authority promise %u %llu %llu %llu %llu", &p, &term, &gen, &ttl, &nonce) == 5
					&& write_promise::promise(1 /* the replica's own partition in this one-process model: the master asked about partition p */, term, gen, ttl, why)) {
				snprintf(reply, sizeof(reply), "PROMISED %llu\r\n", nonce);
			} else {
				snprintf(reply, sizeof(reply), "SERVER_ERROR %s\r\n", why.c_str());
			}
			if (write(fd, reply, strlen(reply)) < 0) {
				// the client is gone
			}
			close(fd);
		}
		return NULL;
	}

	static void srv_start()
	{
		srv_fd = socket(AF_INET, SOCK_STREAM, 0);
		int one = 1;
		setsockopt(srv_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		struct sockaddr_in a;
		memset(&a, 0, sizeof(a));
		a.sin_family = AF_INET;
		a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		a.sin_port = 0;
		cut_assert_equal_int(0, bind(srv_fd, reinterpret_cast<struct sockaddr*>(&a), sizeof(a)));
		cut_assert_equal_int(0, listen(srv_fd, 4));
		socklen_t l = sizeof(a);
		getsockname(srv_fd, reinterpret_cast<struct sockaddr*>(&a), &l);
		srv_port = ntohs(a.sin_port);
		srv_stop = false;
		pthread_create(&srv_th, NULL, srv_main, NULL);
	}

	static void srv_end()
	{
		srv_stop = true;
		pthread_join(srv_th, NULL);
		close(srv_fd);
	}

	void test_the_master_thread_gets_its_grant_from_a_real_promise_over_tcp()
	{
		srv_start();
		mock_cluster cl("localhost", 12121);
		handler_authority h(shared_thread(), &cl);
		char key[64];
		snprintf(key, sizeof(key), "127.0.0.1:%d", srv_port);
		std::string why;
		std::vector<std::string> ks(1, key);
		cut_assert_true(write_promise::set_members(0, 1, 1, TTL_MS, RENEW_MS, ks, why));
		cut_assert_false(write_fence::authority_valid(0));
		cut_assert_true(h.run_once());
		cut_assert_true(write_fence::authority_valid(0));							// granted by the replica's promise
		cut_assert_true(write_promise::get_status(1).have_promise);					// recorded on the replica
		// the replica is prepared by the operator: the next round gets no promise, the grant is not renewed
		write_promise::status s;
		cut_assert_true(write_promise::prepare(1, 3, 2, s, why));
		fake_ns += RENEW_MS * 1000000ULL;
		cut_assert_true(h.run_once());
		cut_assert_true(write_fence::authority_valid(0));							// still within the last grant
		fake_ns += TTL_MS * 1000000ULL;
		cut_assert_false(write_fence::authority_valid(0));							// the master stops by itself
		srv_end();
	}

	void test_unreachable_successors_give_no_grant_and_solo_is_not_asked()
	{
		mock_cluster cl("localhost", 12121);
		handler_authority h(shared_thread(), &cl);
		std::string why;
		std::vector<std::string> ks(1, "127.0.0.1:1");						// nothing listens there
		cut_assert_true(write_promise::set_members(0, 1, 1, TTL_MS, RENEW_MS, ks, why));
		cut_assert_true(h.run_once());
		cut_assert_false(write_fence::authority_valid(0));
		cut_assert_true(write_promise::set_solo(0, 1, 2, why));
		fake_ns += 1000 * S;
		cut_assert_false(h.run_once());										// solo: no request goes out
		cut_assert_true(write_fence::authority_valid(0));
	}

	// A successor that never answers costs ITS partition up to ttl/4 and nobody else's: the rounds
	// of two partitions run on their own threads (a serial loop would have held the healthy one
	// behind the dead one's timeout).
	void test_a_dead_successor_of_one_partition_does_not_delay_another_partitions_round()
	{
		srv_start();
		// a peer that accepts the connection (the kernel does) and never answers
		int dead = socket(AF_INET, SOCK_STREAM, 0);
		struct sockaddr_in a;
		memset(&a, 0, sizeof(a));
		a.sin_family = AF_INET;
		a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		a.sin_port = 0;
		cut_assert_equal_int(0, bind(dead, reinterpret_cast<struct sockaddr*>(&a), sizeof(a)));
		cut_assert_equal_int(0, listen(dead, 4));
		socklen_t l = sizeof(a);
		getsockname(dead, reinterpret_cast<struct sockaddr*>(&a), &l);
		const int dead_port = ntohs(a.sin_port);
		mock_cluster cl("localhost", 12121);
		handler_authority h(shared_thread(), &cl);
		char k0[64], k2[64];
		snprintf(k0, sizeof(k0), "127.0.0.1:%d", srv_port);
		snprintf(k2, sizeof(k2), "127.0.0.1:%d", dead_port);
		std::string why;
		cut_assert_true(write_promise::set_members(2, 1, 1, TTL_MS, RENEW_MS, std::vector<std::string>(1, k2), why));
		cut_assert_true(write_promise::set_members(0, 1, 1, TTL_MS, RENEW_MS, std::vector<std::string>(1, k0), why));
		cppcut_assert_equal(static_cast<size_t>(2), h.dispatch());
		// the healthy partition's grant arrives while the dead one's request is still waiting
		bool granted = false;
		for (int i = 0; i < 100 && !granted; i++) {
			usleep(10000);
			granted = write_fence::authority_valid(0);
		}
		cut_assert_true(granted);
		cut_assert_false(write_fence::authority_valid(2));
		cppcut_assert_equal(static_cast<size_t>(0), h.dispatch());			// both busy or not yet due: no second round on top
		close(dead);
		srv_end();
	}
}
