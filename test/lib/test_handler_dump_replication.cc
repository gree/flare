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
 *	test_handler_dump_replication.cc
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 */

#include "app.h"
#include "stats.h"
#include "handler_dump_replication.h"
#include "mock_cluster.h"
#include "server.h"
#include "mock_storage.h"

#include <cppcutter.h>
#include <time.h>

using namespace std;
using namespace gree::flare;

namespace test_handler_dump_replication {
	void sa_usr1_handler(int sig) {
		// just ignore
	}

	int										port;
	mock_cluster*					cl;
	mock_storage*					st;
	server*								s;
	AtomicCounter *thread_idx;
	thread_pool*					tp;
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

		cl = new mock_cluster("localhost", port);
		thread_idx = new AtomicCounter(1);
		tp = new thread_pool(5, 128, thread_idx);
		st = new mock_storage("", 0, 0);
		st->open();
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
		st->close();

		delete s;
		delete tp;
		delete thread_idx;
		delete st;
		delete cl;
		delete stats_object;

		if (sigaction(SIGUSR1, &prev_sigusr1_action, NULL) < 0) {
			log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
			return;
		}
	}

	void prepare_storage(int item_num, int size = 0) {
		for (int i = 0; i < item_num; i++) {
			string key = "key" + boost::lexical_cast<string>(i);
			if (size > 0) {
				ostringstream data;
				for (int j = 0; j < size; j++) {
					data << "o";
				}
				st->set_helper(key, data.str(), 0);
			} else {
				st->set_helper(key, "VALUE", 0, 0);
			}
		}
	}

	shared_thread start_handler(bool listen = true) {
		shared_thread t = tp->get(thread_pool::thread_type_dump_replication);
		handler_dump_replication* h = new handler_dump_replication(t, cl, st, "localhost", port);
		t->trigger(h, true, false);
		if (listen) {
			s->listen(port);
			cs = s->wait();
		}
		return t;
	}

	// monotonic microseconds, not truncated wall-clock milliseconds: with
	// truncation a correct run of, for example, 500.4 ms (a hypothetical
	// value — the failing run's elapsed time was not recorded) reads as 500
	// and fails "> 500"
	static long now_usec() {
		struct timespec ts;
		clock_gettime(CLOCK_MONOTONIC, &ts);
		return ts.tv_sec * 1000000L + ts.tv_nsec / 1000L;
	}

	// `before_ack_usec`: the monotonic time taken right BEFORE the reply is
	// sent — the handler can start its wait as soon as it has the reply, so
	// only a time taken before sending is causally before that wait
	void response_dump(string response, int key_id, int data_size = 0, long* before_ack_usec = NULL) {
		int size = 5;
		string data = "VALUE\n";
		if (data_size > 0) {
			ostringstream tmp;
			for (int i = 0; i < data_size; i++) {
				tmp << "o";
			}
			data = tmp.str() + "\n";
			size = data_size;
		}
		if (response.length() > 0 && cs.size() > 0) {
			char *p, *q;
			cs[0]->readline(&p);
			cs[0]->readline(&q);
			if (before_ack_usec != NULL) {
				*before_ack_usec = now_usec();
			}
			cs[0]->writeline(response.c_str());
			string req = "set key" + boost::lexical_cast<string>(key_id) + " 0 0 " + boost::lexical_cast<string>(size) + "\n";
			cut_assert_equal_string(req.c_str(), p);
			cut_assert_equal_string(data.c_str(), q);
			delete[] p;
			delete[] q;
		}
	}


	void test_run_success_single_partition() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		prepare_storage(5);

		// execute
		shared_thread t = start_handler();
		for (int i = 0; i < 5; i++) {
			response_dump("STORED", i);
		}

		// assert
		usleep(100 * 1000);  // waiting for dump completed
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("", t->get_state().c_str());
	}

	void test_run_success_two_partition() {
		// prepare
		cluster::node master1 = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cluster::node master2 = cl->set_node("dummy", port + 1, cluster::role_master, cluster::state_active, 1);
		cl->set_partition(0, master1);
		cl->set_partition(1, master2);
		prepare_storage(10);

		// execute
		shared_thread t = start_handler();
		// assigned key to this partition is half of all keys when hash algorithm is simple
		// (key0, key2, key4, key6, key8)
		for (int i = 0; i < 5; i++) {
			response_dump("STORED", i * 2);
		}

		// assert
		usleep(100 * 1000); // waiting for dump completed
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("", t->get_state().c_str());
	}

	void test_run_success_wait() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		cl->set_reconstruction_interval(100 * 1000); // 100 msecs
		prepare_storage(5);
		const long start_usec = now_usec();

		// execute
		shared_thread t = start_handler();
		long before_first_ack = 0;
		for (int i = 0; i < 5; i++) {
			response_dump("STORED", i, 0, i == 0 ? &before_first_ack : NULL);
		}
		// the throttle's invariant: after each reply the handler sleeps at
		// least the interval (100 ms) before sending the next set, so from
		// just BEFORE the first reply until request 4 has arrived there are at
		// least 4 x 100 ms (usleep sleeps at least what it is asked; exactly
		// 400 ms is correct). The start point precedes the first wait
		// causally: it is taken before the reply that lets the handler go on.
		long gap_usec = now_usec() - before_first_ack;
		cut_assert_operator(gap_usec, >=, 4 * 100 * 1000L);

		usleep(100 * 1000); // waiting for completion of sleep of last key

		long elapsed_usec = now_usec() - start_usec;
		// the upper bound only guards against a gross overshoot (1000 ms was
		// too tight for a loaded CI runner: 1003 ms observed)
		cut_assert_operator(elapsed_usec, >=, 500 * 1000L);
		cut_assert_operator(elapsed_usec, <, 2000 * 1000L);

		usleep(100 * 1000); // waiting for dump completed
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("", t->get_state().c_str());
	}

	void test_run_success_bwlimit() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		cl->set_reconstruction_bwlimit(1); // 1 KB
		prepare_storage(5, 100); // 5 keys * 500 Bytes ("VALUE") / 1 KBytes = about 500 msecs
		const long start_usec = now_usec();

		// execute
		shared_thread t = start_handler();
		for (int i = 0; i < 5; i++) {
			response_dump("STORED", i, 100);
		}

		usleep(200 * 1000); // waiting for dump completed
		long elapsed_usec = now_usec() - start_usec;
		// Lower bound proves the throttle actually slept (500 ms exactly is
		// correct, so >=, in microseconds); the upper bound only guards against
		// a gross overshoot (1000 ms was too tight for a loaded CI runner).
		// Both values are printed on failure.
		cut_assert_operator(elapsed_usec, >=, 500 * 1000L);
		cut_assert_operator(elapsed_usec, <, 2000 * 1000L);

		usleep(100 * 1000);
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("", t->get_state().c_str());
	}

	void test_run_success_shutdown_graceful() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		prepare_storage(2);
		st->iter_wait = 100 * 1000;  // 100 msecs

		// execute
		shared_thread t = start_handler();
		response_dump("STORED", 0);  // response only first data
		cut_assert_equal_int(0, t->shutdown(true, false));

		// assert
		usleep(200 * 1000); // waiting for shutdown
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("", t->get_state().c_str());
	}

	void test_run_success_shutdown_not_graceful() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		prepare_storage(2);
		st->iter_wait = 100 * 1000;  // 100 msecs

		// execute
		shared_thread t = start_handler();
		response_dump("STORED", 0);  // response only first data
		cut_assert_equal_int(0, t->shutdown(false, false));

		// assert
		usleep(200 * 1000); // waiting for shutdown (not graceful)
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("shutdown", t->get_state().c_str());
	}

	void test_run_failure_unreachable_connection() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		prepare_storage(3);

		// execute
		shared_thread t = start_handler(false);

		// assert
		sleep(6);  // waiting for connection failure
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("", t->get_state().c_str());
	}

	void test_run_failure_database_busy() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		prepare_storage(3);
		st->iter_begin();

		// execute
		shared_thread t = start_handler();

		// assert
		usleep(100 * 1000);  // waiting for database busy
		cut_assert_equal_boolean(false, t->is_running());
		cut_assert_equal_string("", t->get_state().c_str());
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
