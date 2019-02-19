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

	void test_run_failure_unreachable_connection() {
		// execute
		shared_thread t = start_handler(false);

		// assert
		sleep(6);  // waiting for connection failure
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("", t->get_state().c_str());
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
