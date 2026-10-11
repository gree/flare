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

#include <cppcutter.h>
#include <time.h>

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
		queue_proxy_write::foreign_retry_window_ms = 8000;
		shared_thread t = start_handler(false);
		shared_queue_proxy_write q = enqueue_foreign_set(t, "key");
		usleep(1500 * 1000);
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
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
