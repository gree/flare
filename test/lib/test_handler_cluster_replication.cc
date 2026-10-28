/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
/**
 *	test_handler_cluster_replication.cc
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 */

#include "app.h"
#include "stats.h"
#include "handler_cluster_replication.h"
#include "queue_proxy_read.h"
#include "queue_proxy_write.h"
#include "server.h"
#include "storage.h"
#include "cluster.h"
#include "cluster_replication.h"
#include "op_set.h"

#include <cppcutter.h>
#include <time.h>
#include <set>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

using namespace std;
using namespace gree::flare;

namespace test_handler_cluster_replication {
	void sa_usr1_handler(int sig) {
		// just ignore
	}

	int							port;
	server*					s;
	AtomicCounter *thread_idx;
	thread_pool*		tp;
	vector<shared_connection_tcp>		cs;
	struct sigaction	prev_sigusr1_action;

	void setup() {
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = sa_usr1_handler;
		if (sigaction(SIGUSR1, &sa, &prev_sigusr1_action) < 0) {
			log_err("sigaction for %d failed, %s (%d)", SIGUSR1, util::strerror(errno), errno);
			return;
		}

		stats_object = new stats();
		stats_object->update_timestamp();

		port = rand() % (65535 - 1024) + 1024;
		s = new server();

		thread_idx = new AtomicCounter(1);
		tp = new thread_pool(1, 128, thread_idx);
	}

	void teardown() {
		for (int i = 0; i < cs.size(); i++) {
			cs[i]->close();
		}
		cs.clear();
		if (s) {
			s->close();
		}
		tp->shutdown();

		delete s;
		delete tp;
		delete thread_idx;
		delete stats_object;
		queue_proxy_write::foreign_retry_window_ms = 120 * 1000;
		queue_proxy_write::hold_window_ms = 0;
		queue_proxy_write::clear_held_given_up();

		if (sigaction(SIGUSR1, &prev_sigusr1_action, NULL) < 0) {
			log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
			return;
		}
	}

	storage::entry get_entry(string input, storage::parse_type type, string value = "") {
		storage::entry e;
		e.parse(input.c_str(), type);
		if (e.size > 0 && value.length() > 0) {
			shared_byte data(new uint8_t[e.size]);
			memcpy(data.get(), value.c_str(), e.size);
			e.data = data;
		}
		return e;
	}

	shared_thread start_handler(bool listen = true) {
		shared_thread t = tp->get(thread_pool::thread_type_cluster_replication);
		handler_cluster_replication* h = new handler_cluster_replication(t, "localhost", port);
		t->trigger(h, true, false);
		if (listen) {
			s->listen(port);
			cs = s->wait();
		}
		return t;
	}

	void enqueue(shared_thread t, shared_thread_queue q) {
		t->enqueue(q);
	}

	void replicate_sync(shared_thread t, shared_thread_queue q, string response, string exp_request, string exp_value) {
		q->sync_ref();
		t->enqueue(q);
		if (response.length() > 0 && cs.size() > 0) {
			char *p, *q;
			cs[0]->readline(&p);
			cs[0]->readline(&q);
			cut_assert_equal_string(exp_request.c_str(), p);
			cut_assert_equal_string(exp_value.c_str(), q);
			cs[0]->writeline(response.c_str());
			delete[] p;
			delete[] q;
		}
		q->sync();
	}

	void test_run_success_sync() {
		// prepare
		shared_thread t = start_handler();

		// execute
		for (int i = 0; i < 5; i++) {
			storage::entry e = get_entry(" key 0 0 5 3", storage::parse_type_set, "VALUE");
			vector<string> proxy;
			shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
			q->set_post_proxy(true);
			replicate_sync(t, q, "STORED", "set key 0 0 5 3\n", "VALUE\n"); 
			cut_assert_equal_int(0, stats_object->get_total_thread_queue());
			cut_assert_equal_boolean(true, q->is_success());
			cut_assert_equal_int(op::result_stored, q->get_result());
		}

		// assert
		usleep(100 * 1000);  // waiting for all queue proceeded
		cut_assert_equal_boolean(true, t->is_running());
		cut_assert_equal_string("wait", t->get_state().c_str());
	}

	void test_run_success_async() {
		// prepare
		shared_thread t = start_handler();
		shared_queue_proxy_write queues[5];

		// execute
		for (int i = 0; i < 5; i++) {
			storage::entry e = get_entry(" key 0 0 5 3", storage::parse_type_set, "VALUE");
			vector<string> proxy;
			shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
			q->set_post_proxy(true);
			queues[i] = q;
			enqueue(t, q);
		}

		// assert
		for (int i = 0; i < 5; i++) {
			char *p, *q;
			cs[0]->readline(&p);
			cs[0]->readline(&q);
			cut_assert_equal_string("set key 0 0 5 3\n", p);
			cut_assert_equal_string("VALUE\n", q);
			cs[0]->writeline("STORED");
			usleep(100 * 1000); // waiting for queue proceeded
			cut_assert_equal_boolean(true, queues[i]->is_success());
			cut_assert_equal_int(op::result_stored, queues[i]->get_result());
		}

		cut_assert_equal_boolean(true, t->is_running());
		cut_assert_equal_string("wait", t->get_state().c_str());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_run_shutdown_graceful() {
		// prepare
		shared_thread t = start_handler();

		// execute
		cut_assert_equal_int(0, t->shutdown(true, false));

		// assert
		usleep(200 * 1000);  // waiting for shutdown completed
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("", t->get_state().c_str());
	}

	void test_run_shutdown_not_graceful() {
		// prepare
		shared_thread t = start_handler();

		// execute
		cut_assert_equal_int(0, t->shutdown(false, false));

		// assert
		usleep(200 * 1000);  // waiting for shutdown completed
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("shutdown", t->get_state().c_str());
		cut_assert_equal_boolean(true, t->is_shutdown_request());
	}

	// The first connect fails: the thread STAYS (it used to return and leave
	// the pool while the replication stayed started — every later forward was
	// then an uncounted "no available thread" drop; cross-cluster audit
	// 2026-10-11). A forward to the unreachable destination is counted as
	// dropped; once the destination listens, the next forward is delivered.
	void test_run_failure_unreachable_connection() {
		// execute
		shared_thread t = start_handler(false);

		// assert
		sleep(6);  // waiting for connection failure
		cut_assert_equal_boolean(true, t->is_running());
		cut_assert_equal_string("wait", t->get_state().c_str());

		storage::entry e = get_entry(" key 0 0 5 3", storage::parse_type_set, "VALUE");
		vector<string> proxy;
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
		q->set_post_proxy(true);
		q->sync_ref();
		enqueue(t, q);
		q->sync();  // all retries done
		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());

		s->listen(port);
		storage::entry e2 = get_entry(" key2 0 0 5 3", storage::parse_type_set, "VALUE");
		shared_queue_proxy_write q2(new queue_proxy_write(NULL, NULL, proxy, e2, "set"));
		q2->set_post_proxy(true);
		q2->sync_ref();
		enqueue(t, q2);
		cs = s->wait();
		cut_assert_equal_int(1, (int)cs.size());
		char *p, *v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cut_assert_equal_string("set key2 0 0 5 3\n", p);
		cs[0]->writeline("STORED");
		delete[] p;
		delete[] v;
		q2->sync();
		cut_assert_equal_boolean(true, q2->is_success());
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());
	}

	// Cross-cluster answers, op by op (audit 2026-10-11): an idempotent
	// answer is not a loss, any other non-success answer is.
	void test_classify_foreign_answer() {
		cut_assert_equal_int(queue_proxy_write::foreign_applied, queue_proxy_write::classify_foreign_answer("set", op::result_stored));
		cut_assert_equal_int(queue_proxy_write::foreign_noop, queue_proxy_write::classify_foreign_answer("set", op::result_not_stored));
		cut_assert_equal_int(queue_proxy_write::foreign_failed, queue_proxy_write::classify_foreign_answer("set", op::result_server_error));
		cut_assert_equal_int(queue_proxy_write::foreign_failed, queue_proxy_write::classify_foreign_answer("set", op::result_client_error));
		cut_assert_equal_int(queue_proxy_write::foreign_failed, queue_proxy_write::classify_foreign_answer("set", op::result_error));
		cut_assert_equal_int(queue_proxy_write::foreign_failed, queue_proxy_write::classify_foreign_answer("set", op::result_exists));
		cut_assert_equal_int(queue_proxy_write::foreign_failed, queue_proxy_write::classify_foreign_answer("set", op::result_not_found));
		cut_assert_equal_int(queue_proxy_write::foreign_failed, queue_proxy_write::classify_foreign_answer("set", op::result_none));
		cut_assert_equal_int(queue_proxy_write::foreign_applied, queue_proxy_write::classify_foreign_answer("delete", op::result_deleted));
		cut_assert_equal_int(queue_proxy_write::foreign_noop, queue_proxy_write::classify_foreign_answer("delete", op::result_not_found));
		cut_assert_equal_int(queue_proxy_write::foreign_failed, queue_proxy_write::classify_foreign_answer("delete", op::result_server_error));
		cut_assert_equal_int(queue_proxy_write::foreign_failed, queue_proxy_write::classify_foreign_answer("delete", op::result_not_stored));
		cut_assert_equal_int(queue_proxy_write::foreign_applied, queue_proxy_write::classify_foreign_answer("touch", op::result_touched));
		cut_assert_equal_int(queue_proxy_write::foreign_missing, queue_proxy_write::classify_foreign_answer("touch", op::result_not_found));
		cut_assert_equal_int(queue_proxy_write::foreign_failed, queue_proxy_write::classify_foreign_answer("touch", op::result_server_error));
	}

	uint64_t crepl(const string& name) {
		map<string, uint64_t> m = stats_object->get_crepl();
		map<string, uint64_t>::const_iterator it = m.find(name);
		return it == m.end() ? 0 : it->second;
	}

	// one forwarded set, answered with `response`; returns the request line
	string forward_set(shared_thread t, bool foreign, const string& input, const string& response) {
		storage::entry e = get_entry(input, storage::parse_type_set, "VALUE");
		vector<string> proxy;
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
		q->set_post_proxy(true);
		q->set_foreign(foreign);
		q->sync_ref();
		enqueue(t, q);
		char *p, *v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		string line(p);
		cs[0]->writeline(response.c_str());
		delete[] p;
		delete[] v;
		q->sync();
		return line;
	}

	// A destination that ANSWERS SERVER_ERROR did not store the write: before,
	// that was a rate-limited warning and nothing was counted.
	void test_foreign_server_error_is_counted() {
		queue_proxy_write::foreign_retry_window_ms = 0;  // the answer is final: no resend
		shared_thread t = start_handler();
		forward_set(t, true, " key 0 0 5 3", "SERVER_ERROR proxy error");
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(1, (int)crepl("forward_failed_set_server_error"));
		cut_assert_equal_int(0, (int)crepl("forward_applied"));
	}

	// NOT_STORED to a versioned set: the destination holds this version or a
	// newer one (a retry whose first reply was lost) — not a loss.
	void test_foreign_not_stored_is_noop() {
		shared_thread t = start_handler();
		forward_set(t, true, " key 0 0 5 3", "NOT_STORED");
		forward_set(t, true, " key 0 0 5 4", "STORED");
		cut_assert_equal_int(0, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(1, (int)crepl("forward_noop_set_not_stored"));
		cut_assert_equal_int(1, (int)crepl("forward_applied"));
	}

	// A client's noreply is not passed on to another cluster: the answer is
	// read, so a refusal is seen and counted.
	void test_foreign_noreply_answer_is_read() {
		queue_proxy_write::foreign_retry_window_ms = 0;  // the answer is final: no resend
		shared_thread t = start_handler();
		string line = forward_set(t, true, " key 0 0 5 3 noreply", "SERVER_ERROR i/o error");
		cut_assert_equal_string("set key 0 0 5 3\n", line.c_str());
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());
	}

	// In-cluster forwards keep their behaviour (the answer is logged only).
	void test_in_cluster_server_error_unchanged() {
		shared_thread t = start_handler();
		forward_set(t, false, " key 0 0 5 3", "SERVER_ERROR proxy error");
		cut_assert_equal_int(0, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(0, (int)crepl("forward_failed_set_server_error"));
	}

	string forward_delete(shared_thread t, const string& response) {
		storage::entry e;
		e.key = "key";
		e.version = 3;
		vector<string> proxy;
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "delete"));
		q->set_post_proxy(true);
		q->set_foreign(true);
		q->sync_ref();
		enqueue(t, q);
		char *p;
		cs[0]->readline(&p);
		string line(p);
		cs[0]->writeline(response.c_str());
		delete[] p;
		q->sync();
		return line;
	}

	// delete NOT_FOUND: absent already (or newer there) — not a loss;
	// delete SERVER_ERROR: the key may still be there — counted.
	void test_foreign_delete_answers() {
		queue_proxy_write::foreign_retry_window_ms = 0;  // the answer is final: no resend
		shared_thread t = start_handler();
		cut_assert_equal_string("delete key 0 3\n", forward_delete(t, "NOT_FOUND").c_str());
		cut_assert_equal_int(0, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(1, (int)crepl("forward_noop_delete_not_found"));
		forward_delete(t, "SERVER_ERROR i/o error");
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(1, (int)crepl("forward_failed_delete_server_error"));
		forward_delete(t, "DELETED");
		cut_assert_equal_int(1, (int)crepl("forward_applied"));
	}

	shared_queue_proxy_write enqueue_foreign_set(shared_thread t, const string& key) {
		storage::entry e = get_entry(" " + key + " 0 0 5 3", storage::parse_type_set, "VALUE");
		vector<string> proxy;
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
		q->set_post_proxy(true);
		q->set_foreign(true);
		q->sync_ref();
		enqueue(t, q);
		return q;
	}

	// The destination is down when the forward is made and comes up within
	// the retry window (a restart): the forward is delivered, nothing is
	// dropped — it used to be dropped after 4 quick tries.
	void test_foreign_rides_out_a_late_destination() {
		queue_proxy_write::foreign_retry_window_ms = 20000;
		shared_thread t = start_handler(false);
		shared_queue_proxy_write q = enqueue_foreign_set(t, "key");
		// one attempt is one open() = 2 connects 0.5 s apart (plus the
		// handler's own first open); listen well after the first attempt
		// (nix-linux 38120332346: listening at 1.5 s let it in at once)
		usleep(4000 * 1000);
		s->listen(port);
		cs = s->wait();
		char *p, *v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cut_assert_equal_string("set key 0 0 5 3\n", p);
		cs[0]->writeline("STORED");
		delete[] p;
		delete[] v;
		q->sync();
		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(0, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(1, (int)crepl("forward_retried"));
		cut_assert_equal_int(1, (int)crepl("forward_applied"));
	}

	// The window runs out: that forward is dropped and counted; the next one
	// makes ONE attempt and is counted at once (a dead destination does not
	// hold every write for the whole window); once the destination listens,
	// the next forward is delivered and the wait applies again.
	void test_foreign_gives_up_then_tries_once_each() {
		queue_proxy_write::foreign_retry_window_ms = 1500;
		shared_thread t = start_handler(false);
		shared_queue_proxy_write q1 = enqueue_foreign_set(t, "key1");
		q1->sync();
		cut_assert_equal_boolean(false, q1->is_success());
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(1, (int)crepl("forward_dropped_retries"));

		struct timespec t0, t1;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		shared_queue_proxy_write q2 = enqueue_foreign_set(t, "key2");
		q2->sync();
		clock_gettime(CLOCK_MONOTONIC, &t1);
		long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
		cut_assert_equal_boolean(false, q2->is_success());
		cut_assert_equal_int(2, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(1, (int)crepl("forward_dropped_down"));
		cut_assert(ms < 1500, cut_message("a given-up destination still held the forward %ld ms", ms));

		s->listen(port);
		shared_queue_proxy_write q3 = enqueue_foreign_set(t, "key3");
		cs = s->wait();
		char *p, *v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cut_assert_equal_string("set key3 0 0 5 3\n", p);
		cs[0]->writeline("STORED");
		delete[] p;
		delete[] v;
		q3->sync();
		cut_assert_equal_boolean(true, q3->is_success());
		cut_assert_equal_int(2, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(1, (int)crepl("forward_applied"));
	}

	shared_queue_proxy_write enqueue_replica_set(shared_thread t, const string& key) {
		storage::entry e = get_entry(" " + key + " 0 0 5 3", storage::parse_type_set, "VALUE");
		vector<string> proxy;
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
		q->set_post_proxy(true);
		q->sync_ref();
		enqueue(t, q);
		return q;
	}

	// L12: a replica recreated under the same name does not answer at first
	// (its name still resolves to the old pod's address). Without a hold
	// window the forward is dropped after the 4 quick tries — the write the
	// client was told STORED is missing on that replica (the rolling-restart
	// loss of rc68 runs 40449075597 / 40449096897).
	void test_in_cluster_forward_without_hold_is_dropped() {
		queue_proxy_write::hold_window_ms = 0;
		shared_thread t = start_handler(false);
		shared_queue_proxy_write q = enqueue_replica_set(t, "key");
		q->sync();
		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());
	}

	// With the hold window the same forward waits the replica out and is
	// delivered once it answers: nothing dropped.
	void test_in_cluster_forward_is_held_until_the_replica_answers() {
		queue_proxy_write::hold_window_ms = 20000;
		shared_thread t = start_handler(false);
		shared_queue_proxy_write q = enqueue_replica_set(t, "key");
		// well after the first attempts (one open = 2 connects, see
		// test_foreign_rides_out_a_late_destination)
		usleep(4000 * 1000);
		s->listen(port);
		cs = s->wait();
		char *p, *v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cut_assert_equal_string("set key 0 0 5 3\n", p);
		cs[0]->writeline("STORED");
		delete[] p;
		delete[] v;
		q->sync();
		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, (int)stats_object->get_proxy_write_dropped());
	}

	// The window runs out: that forward is dropped and counted; the next one
	// makes ONE attempt and is counted at once (a dead replica does not hold
	// every write for the whole window); once the replica answers, the next
	// forward is delivered.
	void test_in_cluster_hold_gives_up_then_tries_once_each() {
		queue_proxy_write::hold_window_ms = 1500;
		shared_thread t = start_handler(false);
		shared_queue_proxy_write q1 = enqueue_replica_set(t, "key1");
		q1->sync();
		cut_assert_equal_boolean(false, q1->is_success());
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());

		struct timespec t0, t1;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		shared_queue_proxy_write q2 = enqueue_replica_set(t, "key2");
		q2->sync();
		clock_gettime(CLOCK_MONOTONIC, &t1);
		long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
		cut_assert_equal_boolean(false, q2->is_success());
		cut_assert_equal_int(2, (int)stats_object->get_proxy_write_dropped());
		cut_assert(ms < 1500, cut_message("a given-up replica still held the forward %ld ms", ms));

		s->listen(port);
		shared_queue_proxy_write q3 = enqueue_replica_set(t, "key3");
		cs = s->wait();
		char *p, *v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cut_assert_equal_string("set key3 0 0 5 3\n", p);
		cs[0]->writeline("STORED");
		delete[] p;
		delete[] v;
		q3->sync();
		cut_assert_equal_boolean(true, q3->is_success());
		cut_assert_equal_int(2, (int)stats_object->get_proxy_write_dropped());
	}

	long elapsed_ms(const struct timespec& t0) {
		struct timespec t1;
		clock_gettime(CLOCK_MONOTONIC, &t1);
		return (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
	}

	// A replica that restarted and has not got its role back answers
	// SERVER_ERROR: within the hold window it is resent like no answer, and
	// stored the second time (review of cf27570: it was taken as final).
	void test_in_cluster_server_error_is_retried_within_the_hold() {
		queue_proxy_write::hold_window_ms = 8000;
		shared_thread t = start_handler();
		shared_queue_proxy_write q = enqueue_replica_set(t, "key");
		char *p, *v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cs[0]->writeline("SERVER_ERROR no partition available");
		delete[] p;
		delete[] v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cut_assert_equal_string("set key 0 0 5 3\n", p);
		cs[0]->writeline("STORED");
		delete[] p;
		delete[] v;
		q->sync();
		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, (int)stats_object->get_proxy_write_dropped());
		uint64_t failed = 0;
		stats_object->get_proxy_write_failed(failed);
		cut_assert_equal_int(0, (int)failed);
		uint64_t held = 0;
		stats_object->get_proxy_write_held(held);
		cut_assert_equal_int(1, (int)held);
	}

	// answer every forward that arrives on c with `reply` until none arrives
	// for `idle_ms` (the sender stopped trying); returns how many were answered
	int answer_all(shared_connection_tcp c, const char* reply, int idle_ms) {
		c->set_read_timeout(idle_ms);
		int n = 0;
		for (;;) {
			char *p = NULL, *v = NULL;
			if (c->readline(&p) <= 0) {
				break;
			}
			if (c->readline(&v) <= 0) {
				delete[] p;
				break;
			}
			delete[] p;
			delete[] v;
			c->writeline(reply);
			n++;
		}
		return n;
	}

	// One exchange on c: read one forward, answer `reply`.
	void answer_one(shared_connection_tcp c, const char* reply) {
		char *p, *v;
		c->readline(&p);
		c->readline(&v);
		delete[] p;
		delete[] v;
		c->writeline(reply);
	}

	// A replica that refuses (SERVER_ERROR) through the whole hold window is
	// given up like one that does not answer (review of 09624ee: the refusal
	// counted as an answer, so it was never given up and every forward, on
	// every thread, waited out a whole window again). The forward is counted
	// as failed, not dropped. A second thread then makes ONE fast attempt; a
	// SERVER_ERROR answer keeps the replica given up; only a delivery (STORED)
	// lifts it.
	void test_in_cluster_refusal_through_the_hold_gives_the_replica_up() {
		queue_proxy_write::hold_window_ms = 1500;
		shared_thread a = start_handler();
		shared_queue_proxy_write q1 = enqueue_replica_set(a, "key1");
		const int refused = answer_all(cs[0], "SERVER_ERROR no partition available", 2500);
		q1->sync();
		cut_assert(refused >= 2, cut_message("the refused forward was tried %d time(s) within its hold", refused));
		cut_assert_equal_int(op::result_server_error, q1->get_result());
		uint64_t failed = 0;
		stats_object->get_proxy_write_failed(failed);
		cut_assert_equal_int(1, (int)failed);
		cut_assert_equal_int(0, (int)stats_object->get_proxy_write_dropped());

		// another forwarding thread: one attempt, answered SERVER_ERROR at once
		shared_thread b = start_handler(false);
		vector<shared_connection_tcp> bcs;
		for (int i = 0; i < 50 && bcs.size() == 0; i++) {
			bcs = s->wait();
		}
		cut_assert_true(bcs.size() > 0);
		struct timespec t0;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		shared_queue_proxy_write q2 = enqueue_replica_set(b, "key2");
		answer_one(bcs[0], "SERVER_ERROR no partition available");
		q2->sync();
		const long ms = elapsed_ms(t0);
		cut_assert(ms < 1000, cut_message("a given-up replica held the next forward %ld ms", ms));
		cut_assert_equal_int(op::result_server_error, q2->get_result());
		stats_object->get_proxy_write_failed(failed);
		cut_assert_equal_int(2, (int)failed);

		// still given up after that refusal: the next one is also one attempt
		clock_gettime(CLOCK_MONOTONIC, &t0);
		shared_queue_proxy_write q3 = enqueue_replica_set(b, "key3");
		answer_one(bcs[0], "SERVER_ERROR no partition available");
		q3->sync();
		cut_assert(elapsed_ms(t0) < 1000, cut_message("a SERVER_ERROR lifted the given-up mark"));

		// a delivery lifts it: the next refusal is held (resent) again
		shared_queue_proxy_write q4 = enqueue_replica_set(b, "key4");
		answer_one(bcs[0], "STORED");
		q4->sync();
		cut_assert_equal_int(op::result_stored, q4->get_result());
		shared_queue_proxy_write q5 = enqueue_replica_set(b, "key5");
		answer_one(bcs[0], "SERVER_ERROR no partition available");
		answer_one(bcs[0], "STORED");
		q5->sync();
		cut_assert_equal_int(op::result_stored, q5->get_result());
		for (size_t i = 0; i < bcs.size(); i++) {
			bcs[i]->close();
		}
	}

	// The window is a hard bound on the whole send. A replica that accepts
	// the connection and never answers: every try's read is cut at the time
	// left, so the forward ends (dropped, counted) close to the window and
	// not a read timeout later (review of cf27570).
	void test_in_cluster_hold_is_bounded_by_a_silent_replica() {
		queue_proxy_write::hold_window_ms = 1500;
		s->listen(port);
		shared_thread t = start_handler(false);
		cs = s->wait();
		struct timespec t0;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		shared_queue_proxy_write q = enqueue_replica_set(t, "key");
		q->sync();
		const long ms = elapsed_ms(t0);
		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());
		cut_assert(ms >= 1400 && ms < 2500, cut_message("a silent replica held the forward %ld ms (window 1500)", ms));
	}

	// A replica whose address drops the SYNs (an old pod address, or here a
	// listener whose accept queue is full): every try's connect is cut at
	// the time left, so the forward ends close to the window.
	void test_in_cluster_hold_is_bounded_by_a_blackholed_connect() {
		queue_proxy_write::hold_window_ms = 1500;
		// a listener that never accepts, its accept queue filled
		int lfd = socket(AF_INET, SOCK_STREAM, 0);
		struct sockaddr_in a;
		memset(&a, 0, sizeof(a));
		a.sin_family = AF_INET;
		a.sin_addr.s_addr = inet_addr("127.0.0.1");
		a.sin_port = htons(port);
		int one = 1;
		setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		cut_assert_equal_int(0, bind(lfd, (struct sockaddr*)&a, sizeof(a)));
		cut_assert_equal_int(0, ::listen(lfd, 0));
		vector<int> fill;
		for (int i = 0; i < 4; i++) {
			int f = socket(AF_INET, SOCK_STREAM, 0);
			fcntl(f, F_SETFL, fcntl(f, F_GETFL, 0) | O_NONBLOCK);
			connect(f, (struct sockaddr*)&a, sizeof(a));
			fill.push_back(f);
		}
		usleep(200 * 1000);
		shared_thread t = start_handler(false);
		// the handler's own first open (at thread start, before any forward,
		// with the connection's own connect bounds) is not part of a hold:
		// time the forward from when the thread waits for work
		// (nix 2026-10-27: 8007 ms measured from the thread start)
		for (int i = 0; i < 300 && t->get_state() != "wait"; i++) {
			usleep(100 * 1000);
		}
		cut_assert_equal_string("wait", t->get_state().c_str());
		struct timespec t0;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		shared_queue_proxy_write q = enqueue_replica_set(t, "key");
		q->sync();
		const long ms = elapsed_ms(t0);
		for (size_t i = 0; i < fill.size(); i++) {
			::close(fill[i]);
		}
		::close(lfd);
		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(1, (int)stats_object->get_proxy_write_dropped());
		cut_assert(ms < 2500, cut_message("a blackholed replica held the forward %ld ms (window 1500)", ms));
	}

	// Head of line: each forwarding thread to a replica serializes its own
	// forwards behind a held one. Once ONE thread waited out the window, the
	// replica is given up for every thread: another thread's next forward
	// tries once and is counted at once, instead of waiting out a window of
	// its own (review of cf27570: the mark was per connection). The held
	// counters record how long the held forward waited.
	void test_in_cluster_given_up_is_shared_by_every_forwarding_thread() {
		queue_proxy_write::hold_window_ms = 1500;
		shared_thread a = start_handler(false);
		shared_thread b = start_handler(false);
		shared_queue_proxy_write q1 = enqueue_replica_set(a, "key1");
		q1->sync();
		cut_assert_equal_boolean(false, q1->is_success());
		struct timespec t0;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		shared_queue_proxy_write q2 = enqueue_replica_set(b, "key2");
		q2->sync();
		const long ms = elapsed_ms(t0);
		cut_assert_equal_boolean(false, q2->is_success());
		cut_assert_equal_int(2, (int)stats_object->get_proxy_write_dropped());
		cut_assert(ms < 1000, cut_message("the second thread waited %ld ms although the replica was given up", ms));
		uint64_t held = 0, held_ms_max = 0;
		stats_object->get_proxy_write_held(held);
		stats_object->get_proxy_write_held_ms_max(held_ms_max);
		cut_assert_equal_int(1, (int)held);
		cut_assert(held_ms_max >= 1400, cut_message("held_ms_max %llu", (unsigned long long)held_ms_max));
	}

	// Two threads forwarding to a replica that is down concurrently wait in
	// PARALLEL, not one after the other: the cost of a hold is one window
	// per thread at the same time, not proxy-concurrency windows in a row.
	void test_in_cluster_concurrent_holds_overlap() {
		queue_proxy_write::hold_window_ms = 1500;
		shared_thread a = start_handler(false);
		shared_thread b = start_handler(false);
		struct timespec t0;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		shared_queue_proxy_write q1 = enqueue_replica_set(a, "key1");
		shared_queue_proxy_write q2 = enqueue_replica_set(b, "key2");
		q1->sync();
		q2->sync();
		const long ms = elapsed_ms(t0);
		cut_assert_equal_int(2, (int)stats_object->get_proxy_write_dropped());
		cut_assert(ms < 2500, cut_message("two concurrent holds took %ld ms (window 1500)", ms));
	}

	// SERVER_ERROR is transient (a restarted destination without its role):
	// resent within the window, and stored the second time — nothing lost,
	// nothing counted (50f65f1 restart test: 21 such answers, none counted).
	void test_foreign_server_error_is_retried_within_the_window() {
		queue_proxy_write::foreign_retry_window_ms = 8000;
		shared_thread t = start_handler();
		shared_queue_proxy_write q = enqueue_foreign_set(t, "key");
		char *p, *v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cs[0]->writeline("SERVER_ERROR no partition available");
		delete[] p;
		delete[] v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cut_assert_equal_string("set key 0 0 5 3\n", p);
		cs[0]->writeline("STORED");
		delete[] p;
		delete[] v;
		q->sync();
		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(0, (int)stats_object->get_proxy_write_dropped());
		cut_assert_equal_int(1, (int)crepl("forward_server_error_retried"));
		cut_assert_equal_int(1, (int)crepl("forward_applied"));
	}

	uint64_t in_flight() {
		uint64_t n = 0;
		stats_object->get_crepl_snapshot(n);
		return n;
	}

	// the handler drops its reference when its loop moves on
	bool in_flight_drains_to(uint64_t want) {
		for (int i = 0; i < 50; i++) {
			if (in_flight() == want) {
				return true;
			}
			usleep(100 * 1000);
		}
		return in_flight() == want;
	}

	shared_queue_proxy_write tracked_foreign_set(shared_thread t, const string& key) {
		storage::entry e = get_entry(" " + key + " 0 0 5 3", storage::parse_type_set, "VALUE");
		vector<string> proxy;
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
		q->set_post_proxy(true);
		q->set_foreign(true);
		q->track_in_flight();
		q->sync_ref();
		enqueue(t, q);
		return q;
	}

	// The migration switch gate needs "nothing in flight" as a value: a
	// forward is counted from the moment it is made until it is destroyed,
	// answered or not — the counters alone read as settled while a forward
	// was queued but not yet counted as enqueued (review 2026-10-12).
	void test_in_flight_counts_a_forward_until_it_is_released() {
		shared_thread t = start_handler();
		cut_assert_equal_int(0, (int)in_flight());
		shared_queue_proxy_write q = tracked_foreign_set(t, "key");
		cut_assert_equal_int(1, (int)in_flight());
		char *p, *v;
		cs[0]->readline(&p);
		cs[0]->readline(&v);
		cut_assert_equal_int(1, (int)in_flight());
		cs[0]->writeline("STORED");
		delete[] p;
		delete[] v;
		q->sync();
		// answered and counted, but this reference keeps it alive — the
		// very fast queue: on_post_proxy_write counts forward_enqueued only
		// after _enqueue returns, so one snapshot can hold the outcome and
		// not yet the enqueue; the gauge says in flight in that same snapshot
		cut_assert_equal_int(1, (int)crepl("forward_applied"));
		cut_assert_equal_int(1, (int)in_flight());
		{
			uint64_t n = 0;
			map<string, uint64_t> snap = stats_object->get_crepl_snapshot(n);
			cut_assert_equal_int(1, (int)n);
			cut_assert_equal_int(1, (int)snap["forward_applied"]);
			cut_assert_equal_int(0, (int)snap["forward_enqueued"]);
		}
		q.reset();
		cut_assert(in_flight_drains_to(0), cut_message("in flight stayed %d after the forward was released", (int)in_flight()));
		// a second call does not count it twice
		storage::entry e = get_entry(" key2 0 0 5 3", storage::parse_type_set, "VALUE");
		vector<string> proxy;
		shared_queue_proxy_write q2(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
		q2->track_in_flight();
		q2->track_in_flight();
		cut_assert_equal_int(1, (int)in_flight());
		q2.reset();
		cut_assert_equal_int(0, (int)in_flight());
	}

	// In-cluster forwards to replicas (NODE-OPS-LOSSLESS-PLAN L2): counted per
	// destination from the moment a forward is made for it until the item is
	// released, whatever ended it; the total and the per-destination values
	// come from one snapshot; a released destination leaves no 0 entry.
	void test_repl_in_flight_counts_per_destination_until_released() {
		uint64_t total = 1;
		map<string, uint64_t> snap = stats_object->get_repl_in_flight(total);
		cut_assert_equal_int(0, (int)total);
		cut_assert_equal_int(0, (int)snap.size());
		storage::entry e = get_entry(" rk 0 0 5 3", storage::parse_type_set, "VALUE");
		vector<string> proxy;
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
		q->set_post_proxy(true);
		q->track_repl_in_flight("a:12121");
		q->track_repl_in_flight("b:12121");
		shared_queue_proxy_write q2(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
		q2->set_post_proxy(true);
		q2->track_repl_in_flight("a:12121");
		snap = stats_object->get_repl_in_flight(total);
		cut_assert_equal_int(3, (int)total);
		cut_assert_equal_int(2, (int)snap["a:12121"]);
		cut_assert_equal_int(1, (int)snap["b:12121"]);
		q.reset();
		snap = stats_object->get_repl_in_flight(total);
		cut_assert_equal_int(1, (int)total);
		cut_assert_equal_int(1, (int)snap["a:12121"]);
		cut_assert_equal_int(0, (int)snap.count("b:12121"));
		q2.reset();
		snap = stats_object->get_repl_in_flight(total);
		cut_assert_equal_int(0, (int)total);
		cut_assert_equal_int(0, (int)snap.size());
		// an uncounted destination is never driven below 0
		stats_object->repl_in_flight_sub("c:12121");
		snap = stats_object->get_repl_in_flight(total);
		cut_assert_equal_int(0, (int)total);
	}

	// review of 8d64aaf: terminal outcomes of answered in-cluster forwards are
	// counted per destination (failed / skipped), with totals from one snapshot
	void test_proxy_write_outcomes_are_counted_per_destination() {
		uint64_t total = 1;
		stats_object->get_proxy_write_failed(total);
		cut_assert_equal_int(0, (int)total);
		stats_object->increment_proxy_write_failed("a:12121");
		stats_object->increment_proxy_write_failed("a:12121");
		stats_object->increment_proxy_write_failed("b:12121");
		stats_object->increment_proxy_write_skipped("a:12121");
		map<string, uint64_t> f = stats_object->get_proxy_write_failed(total);
		cut_assert_equal_int(3, (int)total);
		cut_assert_equal_int(2, (int)f["a:12121"]);
		cut_assert_equal_int(1, (int)f["b:12121"]);
		map<string, uint64_t> k = stats_object->get_proxy_write_skipped(total);
		cut_assert_equal_int(1, (int)total);
		cut_assert_equal_int(1, (int)k["a:12121"]);
	}

	// Shutdown with one forward running and one queued: each ends with
	// exactly ONE outcome (stopping, abandoned), and nothing stays in flight
	// once released — the gate's "enqueued == outcomes when nothing is in
	// flight" holds on this path.
	void test_in_flight_and_outcomes_on_shutdown() {
		queue_proxy_write::foreign_retry_window_ms = 60000;
		shared_thread t = start_handler(false);
		shared_queue_proxy_write q1 = tracked_foreign_set(t, "key1");
		shared_queue_proxy_write q2 = tracked_foreign_set(t, "key2");
		cut_assert_equal_int(2, (int)in_flight());
		// q1 must be RUNNING (dequeued, in its retry wait) when the stop
		// comes: the handler's own first open takes ~1 s against a closed
		// port, and a stop before that left both queued (nix-linux
		// 38215508608: stopping 0)
		bool running = false;
		for (int i = 0; i < 100 && !running; i++) {
			running = stats_object->get_total_thread_queue() == 1;
			if (!running) {
				usleep(100 * 1000);
			}
		}
		cut_assert(running, cut_message("q1 never dequeued (queue %d)", (int)stats_object->get_total_thread_queue()));
		usleep(300 * 1000);
		t->shutdown(true, false);
		q1->sync();
		q2->sync();
		cut_notify("outcomes: stopping=%d abandoned=%d retries=%d down=%d", (int)crepl("forward_dropped_stopping"),
			(int)crepl("forward_dropped_abandoned"), (int)crepl("forward_dropped_retries"), (int)crepl("forward_dropped_down"));
		cut_assert_equal_int(1, (int)crepl("forward_dropped_stopping"));
		cut_assert_equal_int(1, (int)crepl("forward_dropped_abandoned"));
		cut_assert_equal_int(0, (int)crepl("forward_applied"));
		q1.reset();
		q2.reset();
		cut_assert(in_flight_drains_to(0), cut_message("in flight stayed %d after shutdown", (int)in_flight()));
	}

	// Every name an answered forward is counted under, over every op it can
	// be sent as and every answer: exactly the operator gate's closed set
	// (Migration/Types.lean forwardAnsweredCounters; the same literal is in
	// its unit check). A new name here holds every switch until the gate
	// knows it — this test makes that a build failure instead.
	void test_foreign_outcome_counters_are_the_gate_set() {
		const char* sent[] = { "set", "delete", "touch" };
		const op::result answers[] = { op::result_none, op::result_ok, op::result_end, op::result_stored,
			op::result_not_stored, op::result_exists, op::result_not_found, op::result_deleted, op::result_found,
			op::result_touched, op::result_error, op::result_client_error, op::result_server_error };
		set<string> names;
		for (size_t i = 0; i < sizeof(sent) / sizeof(sent[0]); i++) {
			for (size_t j = 0; j < sizeof(answers) / sizeof(answers[0]); j++) {
				names.insert(queue_proxy_write::foreign_outcome_counter(sent[i], answers[j]));
			}
		}
		string joined;
		for (set<string>::const_iterator it = names.begin(); it != names.end(); it++) {
			joined += (joined.empty() ? "" : ",") + *it;
		}
		cut_assert_equal_string("forward_applied,forward_failed_delete_client_error,forward_failed_delete_end,forward_failed_delete_error,forward_failed_delete_exists,forward_failed_delete_found,forward_failed_delete_none,forward_failed_delete_not_stored,forward_failed_delete_ok,forward_failed_delete_server_error,forward_failed_delete_stored,forward_failed_delete_touched,forward_failed_set_client_error,forward_failed_set_deleted,forward_failed_set_end,forward_failed_set_error,forward_failed_set_exists,forward_failed_set_found,forward_failed_set_none,forward_failed_set_not_found,forward_failed_set_ok,forward_failed_set_server_error,forward_failed_set_touched,forward_failed_touch_client_error,forward_failed_touch_deleted,forward_failed_touch_end,forward_failed_touch_error,forward_failed_touch_exists,forward_failed_touch_found,forward_failed_touch_none,forward_failed_touch_not_stored,forward_failed_touch_server_error,forward_failed_touch_stored,forward_missing_touch_not_found,forward_noop_delete_not_found,forward_noop_set_not_stored", joined.c_str());
	}

	// enqueue() checked _running WITHOUT the queue lock: a forward pushed
	// after the handler returned and clean() drained the queue was left on a
	// pooled thread — never run, never counted, in flight for good (or run
	// by the next handler the thread gets). The hook stops the thread in
	// exactly that window.
	bool hook_fired = false;
	void stop_thread_before_enqueue_lock(thread* t) {
		if (hook_fired) {
			return;
		}
		hook_fired = true;
		t->shutdown(true, false);
		for (int i = 0; i < 50 && t->is_running(); i++) {
			usleep(100 * 1000);
		}
		// past notify_shutdown: clean() drains the queue right after
		usleep(500 * 1000);
	}

	void test_enqueue_after_the_handler_returned_is_refused() {
		shared_thread t = start_handler(false);
		cut_assert(t->is_running());
		storage::entry e = get_entry(" late 0 0 5 3", storage::parse_type_set, "VALUE");
		vector<string> proxy;
		shared_queue_proxy_write q(new queue_proxy_write(NULL, NULL, proxy, e, "set"));
		q->set_post_proxy(true);
		q->set_foreign(true);
		q->track_in_flight();
		shared_thread_queue sq = q;
		hook_fired = false;
		thread::enqueue_before_lock_hook = stop_thread_before_enqueue_lock;
		int r = t->enqueue(sq);
		thread::enqueue_before_lock_hook = NULL;
		cut_assert(hook_fired);
		cut_notify("enqueue after the handler returned: r=%d queued=%d", r, (int)stats_object->get_total_thread_queue());
		// refused as "not this run" (-2, thread.h), so the caller counts
		// forward_dropped_unqueued (not an enqueued forward) — nothing left
		// behind on the thread
		cut_assert_equal_int(-2, r);
		cut_assert_equal_int(0, (int)stats_object->get_total_thread_queue());
		sq.reset();
		q.reset();
		cut_assert_equal_int(0, (int)in_flight());
		cut_assert_equal_int(0, (int)crepl("forward_dropped_abandoned"));
	}

	// Review 2026-10-13 [P1]: the queue being open is not enough.
	// cluster_replication::_enqueue copies the active map, releases its lock
	// and enqueues later; in between, the thread can be cleaned and REUSED
	// for another handler (another destination after a reload), whose run
	// opens the queue again. The hook does exactly that between the copy and
	// the enqueue: the forward must be refused and counted as unqueued — not
	// handed to the new handler and sent to its destination.
	thread_pool* reuse_pool = NULL;
	int reuse_port = 0;
	bool reuse_fired = false;
	shared_thread reused;
	void reuse_thread_for_another_destination(thread* t) {
		if (reuse_fired) {
			return;
		}
		reuse_fired = true;
		t->shutdown(true, false);
		for (int i = 0; i < 50 && t->is_running(); i++) {
			usleep(100 * 1000);
		}
		usleep(500 * 1000);		// clean(): back to the pool
		reused = reuse_pool->get(thread_pool::thread_type_cluster_replication);
		handler_cluster_replication* h = new handler_cluster_replication(reused, "localhost", reuse_port);
		reused->trigger(h, true, false);
	}

	void test_post_proxy_forward_is_not_handed_to_a_reused_thread() {
		queue_proxy_write::foreign_retry_window_ms = 60000;
		cluster cl(NULL, NULL, "", 0);
		cluster_replication cr(tp);
		cut_assert_equal_int(0, cr.start("localhost", port, 1, NULL, &cl));
		thread_pool::local_map m = tp->get_active(thread_pool::thread_type_cluster_replication);
		cut_assert_equal_int(1, (int)m.size());
		shared_thread old_t = m.begin()->second;
		const unsigned int old_id = m.begin()->first;
		for (int i = 0; i < 50 && !old_t->is_running(); i++) {
			usleep(100 * 1000);
		}
		cut_assert(old_t->is_running());

		shared_connection c(new connection_tcp("localhost", 1));
		op_set o(c, NULL, NULL);
		o.get_entry() = get_entry(" fk 0 0 5 3", storage::parse_type_set, "VALUE");
		cluster::node n;
		n.node_role = cluster::role_master;
		reuse_pool = tp;
		reuse_port = port + 1;
		reuse_fired = false;
		thread::enqueue_before_lock_hook = reuse_thread_for_another_destination;
		cr.on_post_proxy_write(&o, n);
		thread::enqueue_before_lock_hook = NULL;

		cut_assert(reuse_fired);
		cut_assert(reused, cut_message("no thread for the second handler"));
		// the reuse really happened: the SAME thread object, a NEW id
		cut_assert(reused.get() == old_t.get(), cut_message("the pool gave a new thread, not the cleaned one: the reuse was not reproduced"));
		cut_assert(reused->get_id() != old_id, cut_message("the reused thread kept id %u", old_id));
		usleep(500 * 1000);
		cut_notify("reused thread %u -> %u: enqueued=%d unqueued=%d queued=%d in_flight=%d",
			old_id, reused->get_id(), (int)crepl("forward_enqueued"), (int)crepl("forward_dropped_unqueued"),
			(int)stats_object->get_total_thread_queue(), (int)in_flight());
		cut_assert_equal_int(0, (int)crepl("forward_enqueued"));
		cut_assert_equal_int(1, (int)crepl("forward_dropped_unqueued"));
		cut_assert_equal_int(0, (int)stats_object->get_total_thread_queue());
		cut_assert_equal_int(0, (int)in_flight());
		cut_assert_equal_int(0, (int)crepl("forward_applied"));
		cut_assert_equal_int(0, (int)crepl("forward_dropped_retries"));
		cut_assert_equal_int(0, (int)crepl("forward_dropped_stopping"));
		cut_assert_equal_int(0, (int)crepl("forward_dropped_abandoned"));
		reused.reset();
		cr.stop();
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
