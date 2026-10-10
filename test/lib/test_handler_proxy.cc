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
 * test_handler_proxy.cc
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 */

#include "app.h"
#include "stats.h"
#include "handler_proxy.h"
#include "mock_cluster.h"

#include "queue_proxy_read.h"
#include "queue_proxy_write.h"
#include "server.h"
#include "op_get.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <pthread.h>
#include <errno.h>
#include <cppcutter.h>

#include "logger.h"

using namespace std;
using namespace gree::flare;

namespace test_handler_proxy {
	static const int wait_retry_num = 10;

	// Let the kernel reserve a port instead of guessing one and ignoring
	// bind failure. Keep the listener open until the handler connects.
	struct test_server : server {
		int bound_port() {
			struct sockaddr_in addr;
			socklen_t size = sizeof(addr);
			if (_listen_socket_index == 0 ||
				getsockname(_listen_socket[0], reinterpret_cast<struct sockaddr*>(&addr), &size) != 0) return -1;
			return ntohs(addr.sin_port);
		}
	};

	void sa_usr1_handler(int sig) {
		// just ignore
	}

	int							port;
	mock_cluster*		cl;
	AtomicCounter*		thread_idx;
	thread_pool*		tp;
	server*					s;
	vector<shared_connection_tcp>		cs;
	struct sigaction	prev_sigusr1_action;

	void setup() {
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = sa_usr1_handler;
		if (sigaction(SIGUSR1, &sa, &prev_sigusr1_action) < 0) {
			log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
			return;
		}
#if __APPLE__
		signal(SIGPIPE, SIG_IGN);
#endif

		stats_object = new stats();
		stats_object->update_timestamp();

		test_server* listener = new test_server();
		s = listener;
		cut_assert_equal_int(0, s->listen(0));
		port = listener->bound_port();
		cut_assert_true(port > 0);

		cl = new mock_cluster("localhost", port);
		thread_idx = new AtomicCounter(1);
		tp = new thread_pool(5, 128, thread_idx);
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
		delete cl;
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

	shared_queue_proxy_write get_proxy_queue_write() {
		vector<string> proxy;
		storage::entry e = get_entry(" key 0 0 5 3", storage::parse_type_set, "VALUE");
		shared_queue_proxy_write q(new queue_proxy_write(
				NULL, NULL, proxy, e, "set"));
		return q;
	}

	shared_queue_proxy_read get_proxy_queue_read() {
		vector<string> proxy;
		storage::entry e = get_entry(" key", storage::parse_type_get);
		shared_queue_proxy_read q(new queue_proxy_read(
				NULL, NULL, proxy, e, NULL, "get"));
		return q;
	}

	shared_thread start_handler_proxy(int thread_type) {
		shared_thread t = tp->get(thread_type);
		handler_proxy* h = new handler_proxy(t, cl, "localhost", port);
		t->trigger(h, true, false);
		return t;
	}

	void proxy_request(shared_thread t, shared_thread_queue q, string response) {
		int retry = 0;
		q->sync_ref();
		t->enqueue(q);
		while (cs.size() == 0 && retry < wait_retry_num) {
			cs = s->wait();
			if (cs.size() > 0) {
				break;
			}
			// server->wait() might fail by system call interruption
			// when it is called immediately after server->listen()
			usleep(100 * 1000); // 100 msecs
			retry++;
		}
		if (retry == wait_retry_num) {
			// server failed to establish connection in 1 seconds due to a critical reason
			// so abort test case
			cut_fail("failed to wait for connection establishment");
		}
		if (response.length() > 0) {
			cs[0]->writeline(response.c_str());
		}
		q->sync();
	}

	void proxy_request_to_down_node(shared_thread t, shared_thread_queue q) {
		q->sync_ref();
		t->enqueue(q);
		q->sync();  // this will return by failure of connection_tcp->open() at handler_proxy
	}

	void test_proxy_write_to_master() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");

		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_slave() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_slave, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");

		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_proxy() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_proxy, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, ""); // proxy request should be skip so no response

		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(op::result_none, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_prepare_node() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_prepare);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");

		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_ready_node() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_ready);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");

		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_down_node() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_down);
		shared_thread t = start_handler_proxy(n.node_thread_type);
		s->close();

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request_to_down_node(t, q);

		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(op::result_none, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_master() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q, "VALUE key 0 5\r\nVALUE\r\nEND");

		cut_assert_equal_boolean(true, q->is_success());
		//cut_assert_equal_int(op::result_found, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_slave() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_slave, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q, "VALUE key 0 5\r\nVALUE\r\nEND");

		cut_assert_equal_boolean(true, q->is_success());
		//cut_assert_equal_int(op::result_found, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_proxy() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_proxy, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_read q = get_proxy_queue_read();
		// A skipped request must complete its queue reference. It does not
		// require successful transport: run() skips it before _process_queue.
		q->sync_ref();
		shared_thread_queue queued = q;
		cut_assert_equal_int(0, t->enqueue(queued));
		q->sync();

		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(op::result_none, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_stale_balance_read_guard_uses_production_routing_and_recovers() {
		cluster::node master = cl->set_node("master", 12121, cluster::role_master, cluster::state_active, 0, 100);
		cluster::node slave = cl->set_node("localhost", port, cluster::role_slave, cluster::state_active, 0, 50);
		cl->set_partition(0, master, &slave, 1);
		// R3: a slave copy that was never validated against its source in
		// this process answers nothing locally (forwarded to the master; here
		// no transport target, so enqueue failure — never a local read).
		{
			shared_connection c0;
			op_get op0(c0, cl, NULL);
			storage::entry e0 = get_entry(" key", storage::parse_type_get);
			shared_queue_proxy_read q0;
			cl->clear_node_map();
			cut_assert_equal_int(cluster::proxy_request_error_enqueue, cl->pre_proxy_read(&op0, e0, NULL, q0));
			master = cl->set_node("master", 12121, cluster::role_master, cluster::state_active, 0, 100);
			slave = cl->set_node("localhost", port, cluster::role_slave, cluster::state_active, 0, 50);
		}
		// The follow guard below is checked on a copy bound to its source
		// (as a completed reconstruction binds it), with the map in force.
		cl->bind_read_source("master:12121", "lineage", "epoch", "test: validated copy");
		// Keep the stale positive-balance partition, but no transport target:
		// forced master routing must return enqueue failure, never local read.
		cl->clear_node_map();
		stats_object->follow_set_enabled(true);
		stats_object->follow_set_source("master:12121", "epoch");
		stats_object->follow_note_source_position(100);
		stats_object->follow_note_progress(100);
		stats_object->follow_set_state(stats::follow_following, "");
		shared_connection c;
		op_get op(c, cl, NULL);
		storage::entry e = get_entry(" key", storage::parse_type_get);
		shared_queue_proxy_read q;
		cut_assert_equal_int(cluster::proxy_request_continue, cl->pre_proxy_read(&op, e, NULL, q));
		stats_object->follow_set_state(stats::follow_disconnected, "test-cut");
		cut_assert_equal_int(cluster::proxy_request_error_enqueue, cl->pre_proxy_read(&op, e, NULL, q));
		stats_object->follow_set_state(stats::follow_following, "");
		stats_object->follow_note_source_position(101);
		cut_assert_equal_int(cluster::proxy_request_error_enqueue, cl->pre_proxy_read(&op, e, NULL, q));
		stats_object->follow_note_progress(101);
		cut_assert_equal_int(cluster::proxy_request_continue, cl->pre_proxy_read(&op, e, NULL, q));
		stats_object->follow_set_source("other-master:12121", "other-epoch");
		cut_assert_equal_int(cluster::proxy_request_error_enqueue, cl->pre_proxy_read(&op, e, NULL, q));
	}

	void test_proxy_read_to_prepare_node() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_prepare);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q, "VALUE key 0 5\r\nVALUE\r\nEND");

		cut_assert_equal_boolean(true, q->is_success());
		//cut_assert_equal_int(op::result_found, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_ready_node() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_ready);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q, "VALUE key 0 5\r\nVALUE\r\nEND");

		cut_assert_equal_boolean(true, q->is_success());
		//cut_assert_equal_int(op::result_found, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_down_node() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_down);
		shared_thread t = start_handler_proxy(n.node_thread_type);
		s->close();

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request_to_down_node(t, q);

		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(op::result_none, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	// active -> down -> active
	void test_proxy_state_machine_for_node_state() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());

		cl->set_node("localhost", port, cluster::role_master, cluster::state_down);
		for (int i = 0; i < cs.size(); i++) {
			cs[i]->close();
		}
		s->close();
		delete s;
		s = NULL;

		q = get_proxy_queue_write();
		proxy_request_to_down_node(t, q);
		cut_assert_equal_boolean(false, q->is_success());

		cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		s = new server();
		s->listen(port);
		cs.clear();

		q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());
	}

	// proxy -> master
	void test_proxy_state_machine_when_node_role_going_into_master_from_proxy() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_proxy, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(false, q->is_success());

		cl->set_node("localhost", port, cluster::role_master, cluster::state_active);

		q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());
	}

	// proxy -> slave
	void test_proxy_state_machine_when_node_role_going_into_slave_from_proxy() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_proxy, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(false, q->is_success());

		cl->set_node("localhost", port, cluster::role_slave, cluster::state_active);

		q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());
	}

	// slave -> master (failover)
	void test_proxy_state_machine_when_node_role_going_into_master_from_slave() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_slave, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());

		cl->set_node("localhost", port, cluster::role_master, cluster::state_active);

		q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());
	}

	// master -> slave (invalid case, actually not happen)
	void test_proxy_state_machine_when_node_role_going_into_slave_from_master() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());

		cl->set_node("localhost", port, cluster::role_slave, cluster::state_active);

		q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());
	}

	// master -> proxy
	void test_proxy_state_machine_when_node_role_going_into_proxy_from_master() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());

		cl->set_node("localhost", port, cluster::role_proxy, cluster::state_active);

		q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(false, q->is_success());
	}

	// slave -> proxy
	void test_proxy_state_machine_when_node_role_going_into_proxy_from_slave() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_slave, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());

		cl->set_node("localhost", port, cluster::role_proxy, cluster::state_active);

		q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(false, q->is_success());
	}

	// A destination whose address takes SYNs but never answers (a replaced
	// pod's old IP, forward-window-steps 38048708017): reproduced with a
	// listener whose accept queue is full — Linux drops further SYNs, so a
	// blocking connect hangs for the kernel's SYN timeout (~130 s) per attempt.
	struct sync_args { shared_queue_proxy_write q; volatile bool done; };
	void* run_sync(void* a) {
		sync_args* x = static_cast<sync_args*>(a);
		x->q->sync();
		x->done = true;
		return NULL;
	}



	// a loopback listener whose accept queue is full (Linux drops further
	// SYNs: a connect to it times out); returns its port, fds in `fds`
	int make_unanswering_listener(vector<int>& fds) {
		int lfd = socket(AF_INET, SOCK_STREAM, 0);
		cut_assert_true(lfd >= 0, cut_message("socket() failed: errno %d", errno));
		fds.push_back(lfd);
		struct sockaddr_in addr;
		memset(&addr, 0, sizeof(addr));
		addr.sin_family = AF_INET;
		addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		addr.sin_port = 0;
		int one = 1;
		cut_assert_equal_int(0, setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)), cut_message("setsockopt failed: errno %d", errno));
		cut_assert_equal_int(0, bind(lfd, (struct sockaddr*)&addr, sizeof(addr)), cut_message("bind failed: errno %d", errno));
		cut_assert_equal_int(0, listen(lfd, 0), cut_message("listen failed: errno %d", errno));
		socklen_t len = sizeof(addr);
		cut_assert_equal_int(0, getsockname(lfd, (struct sockaddr*)&addr, &len), cut_message("getsockname failed: errno %d", errno));
		cut_assert_true(ntohs(addr.sin_port) > 0, cut_message("no port assigned"));
		for (int k = 0; k < 4; k++) {
			int f = socket(AF_INET, SOCK_STREAM, 0);
			cut_assert_true(f >= 0, cut_message("filler socket() failed: errno %d", errno));
			fds.push_back(f);
			cut_assert_equal_int(0, fcntl(f, F_SETFL, fcntl(f, F_GETFL, 0) | O_NONBLOCK), cut_message("fcntl failed: errno %d", errno));
			const int cr = connect(f, (struct sockaddr*)&addr, sizeof(addr));
			cut_assert_true(cr == 0 || errno == EINPROGRESS, cut_message("filler connect failed: errno %d", errno));
		}
		usleep(300 * 1000);
		return ntohs(addr.sin_port);
	}

	// enqueue `q` on `t` and wait at most `limit_ms` for its sync; true when it finished
	bool run_with_watchdog(shared_thread t, shared_queue_proxy_write q, int limit_ms, vector<int>& release, pthread_t& th, sync_args& a) {
		q->sync_ref();
		shared_thread_queue tq = q;
		t->enqueue(tq);
		a.q = q;
		a.done = false;
		const int pc = pthread_create(&th, NULL, run_sync, &a);
		if (pc != 0) {
			// no watchdog thread: the forward cannot be waited for safely —
			// release anything that could hang and FAIL (never a silent pass)
			for (size_t k = 0; k < release.size(); k++) {
				::close(release[k]);
			}
			release.clear();
			cut_fail("pthread_create failed (%d): the watchdog could not start", pc);
		}
		int waited = 0;
		while (!a.done && waited < limit_ms) {
			usleep(100 * 1000);
			waited += 100;
		}
		const bool finished = a.done;
		if (!finished) {
			// release a connect still hanging (pending SYNs get a RST)
			for (size_t k = 0; k < release.size(); k++) {
				::close(release[k]);
			}
			release.clear();
		}
		pthread_join(th, NULL);
		return finished;
	}

	void test_proxy_write_to_an_unanswering_address_is_a_counted_drop_within_seconds() {
		vector<int> fds;
		const int bh_port = make_unanswering_listener(fds);
		cluster::node n = cl->set_node("127.0.0.1", bh_port, cluster::role_slave, cluster::state_active);
		shared_thread t = tp->get(n.node_thread_type);
		handler_proxy* h = new handler_proxy(t, cl, "127.0.0.1", bh_port);
		t->trigger(h, true, false);

		const uint64_t dropped0 = stats_object->get_proxy_write_dropped();
		shared_queue_proxy_write q = get_proxy_queue_write();
		q->set_post_proxy(true);
		pthread_t th;
		sync_args a;
		const bool finished = run_with_watchdog(t, q, 20000, fds, th, a);
		for (size_t k = 0; k < fds.size(); k++) {
			::close(fds[k]);
		}
		cut_assert_true(finished, cut_message("the forward was neither sent nor dropped within 20 s (it queued behind a hanging connect)"));
		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_true(stats_object->get_proxy_write_dropped() > dropped0, cut_message("the failed forward was not counted as a drop"));
	}

	// after a TIMED-OUT open was counted as a drop, a later forward (past the
	// fail-fast window) reconnects as soon as the destination answers
	void test_after_a_timed_out_open_a_later_forward_reconnects_once_the_destination_answers() {
		vector<int> fds;
		const int bh_port = make_unanswering_listener(fds);
		cluster::node n = cl->set_node("127.0.0.1", bh_port, cluster::role_slave, cluster::state_active);
		shared_thread t = tp->get(n.node_thread_type);
		handler_proxy* h = new handler_proxy(t, cl, "127.0.0.1", bh_port);
		t->trigger(h, true, false);

		const uint64_t dropped0 = stats_object->get_proxy_write_dropped();
		shared_queue_proxy_write q1 = get_proxy_queue_write();
		q1->set_post_proxy(true);
		pthread_t th;
		sync_args a;
		const bool f1 = run_with_watchdog(t, q1, 20000, fds, th, a);
		const uint64_t dropped1 = stats_object->get_proxy_write_dropped();
		// the destination comes back on the same port
		for (size_t k = 0; k < fds.size(); k++) {
			::close(fds[k]);
		}
		fds.clear();
		server* back = new server();
		const int lr = back->listen(bh_port);
		usleep((handler_proxy::proxy_fail_fast_window_ms + 500) * 1000);	// past the fail-fast window
		shared_queue_proxy_write q2 = get_proxy_queue_write();
		q2->set_post_proxy(true);
		q2->sync_ref();
		shared_thread_queue tq2 = q2;
		t->enqueue(tq2);
		vector<shared_connection_tcp> bcs;
		for (int r = 0; r < 100 && bcs.size() == 0; r++) {
			bcs = back->wait();
			if (bcs.size() == 0) usleep(100 * 1000);
		}
		if (bcs.size() > 0) {
			bcs[0]->writeline("STORED");
		}
		q2->sync();
		const bool ok2 = q2->is_success();
		for (size_t k = 0; k < bcs.size(); k++) {
			bcs[k]->close();
		}
		back->close();
		delete back;
		cut_assert_true(f1, cut_message("the first forward was neither sent nor dropped within 20 s"));
		cut_assert_true(dropped1 > dropped0, cut_message("the timed-out forward was not counted"));
		cut_assert_equal_int(0, lr);
		cut_assert_true(bcs.size() > 0, cut_message("no reconnect after the destination came back"));
		cut_assert_true(ok2, cut_message("the forward after the reconnect did not succeed"));
		cut_assert_equal_int((int)dropped1, (int)stats_object->get_proxy_write_dropped());
	}

	// a client write forwarded TO a master (pre-proxy) through an address that
	// times out fails for the client and is NOT counted as a replica drop
	void test_pre_proxy_write_to_an_unanswering_address_fails_without_a_replica_drop() {
		vector<int> fds;
		const int bh_port = make_unanswering_listener(fds);
		cluster::node n = cl->set_node("127.0.0.1", bh_port, cluster::role_master, cluster::state_active);
		shared_thread t = tp->get(n.node_thread_type);
		handler_proxy* h = new handler_proxy(t, cl, "127.0.0.1", bh_port);
		t->trigger(h, true, false);

		const uint64_t dropped0 = stats_object->get_proxy_write_dropped();
		shared_queue_proxy_write q = get_proxy_queue_write();		// pre-proxy (post_proxy false)
		pthread_t th;
		sync_args a;
		const bool finished = run_with_watchdog(t, q, 20000, fds, th, a);
		for (size_t k = 0; k < fds.size(); k++) {
			::close(fds[k]);
		}
		cut_assert_true(finished, cut_message("the client write was neither answered nor failed within 20 s"));
		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int((int)dropped0, (int)stats_object->get_proxy_write_dropped());
	}

	// the same for a REFUSED master connection (retries exhausted): the client
	// hears the failure, no replica drop is counted (it was, before)
	void test_pre_proxy_write_to_a_refused_master_is_not_a_replica_drop() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);
		s->close();
		const uint64_t dropped0 = stats_object->get_proxy_write_dropped();
		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request_to_down_node(t, q);
		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int((int)dropped0, (int)stats_object->get_proxy_write_dropped());
	}

	// a forward to a replica whose role became PROXY is skipped: counted as a
	// drop when it was a post-proxy forward, not when it was a client write
	void test_post_proxy_forward_skipped_to_a_proxy_is_a_counted_drop() {
		cluster::node n = cl->set_node("localhost", port, cluster::role_proxy, cluster::state_active);
		shared_thread t = start_handler_proxy(n.node_thread_type);
		const uint64_t dropped0 = stats_object->get_proxy_write_dropped();
		shared_queue_proxy_write pre = get_proxy_queue_write();
		proxy_request(t, pre, "STORED");
		cut_assert_equal_boolean(false, pre->is_success());
		cut_assert_equal_int((int)dropped0, (int)stats_object->get_proxy_write_dropped());
		shared_queue_proxy_write post = get_proxy_queue_write();
		post->set_post_proxy(true);
		post->sync_ref();
		shared_thread_queue tq = post;
		t->enqueue(tq);
		post->sync();
		cut_assert_equal_boolean(false, post->is_success());
		cut_assert_equal_int((int)dropped0 + 1, (int)stats_object->get_proxy_write_dropped());
	}

	// forwards still QUEUED when their thread shuts down are counted as drops
	// (post-proxy) — they vanished without a trace before; client writes are not
	// a handler that never dequeues: its queue stays as it is until shutdown
	struct idle_handler : public thread_handler {
		idle_handler(shared_thread t): thread_handler(t) {};
		int run() {
			while (this->_thread->is_shutdown_request() == thread::shutdown_request_none) {
				usleep(10 * 1000);
			}
			return 0;
		};
	};

	void test_forwards_abandoned_at_thread_shutdown_are_counted() {
		shared_thread t = tp->get(42);
		t->trigger(new idle_handler(t), true, false);
		t->set_peer("abandoned.example", 12121);
		const uint64_t dropped0 = stats_object->get_proxy_write_dropped();
		for (int k = 0; k < 3; k++) {
			shared_queue_proxy_write q = get_proxy_queue_write();
			q->set_post_proxy(true);
			shared_thread_queue tq = q;
			cut_assert_equal_int(0, t->enqueue(tq));
		}
		shared_queue_proxy_write pre = get_proxy_queue_write();
		shared_thread_queue tpre = pre;
		cut_assert_equal_int(0, t->enqueue(tpre));
		t->shutdown(false, false);
		cut_assert_equal_int((int)dropped0 + 3, (int)stats_object->get_proxy_write_dropped());
		map<string, uint64_t> by = stats_object->get_proxy_write_dropped_by_dest();
		cut_assert_equal_int(3, (int)by["abandoned.example:12121"]);
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
