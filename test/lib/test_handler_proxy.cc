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

#include <cppcutter.h>

#include "logger.h"

using namespace std;
using namespace gree::flare;

namespace test_handler_proxy {
	static const int wait_retry_num = 10;

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

		port = rand() % (65535 - 1024) + 1024;
		s = new server();

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
		s->listen(port);
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
		proxy_request(t, q, "");  // proxy request should be skipped so no reponse

		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(op::result_none, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
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
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
