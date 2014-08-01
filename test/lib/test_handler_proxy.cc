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
	void sa_usr1_handler(int sig) {
		// just ignore
	}

	int							port;
	mock_cluster*		cl;
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

		stats_object = new stats();
		stats_object->update_timestamp();

		port = rand() % (65535 - 1024) + 1024;
		s = new server();

		cl = new mock_cluster("localhost", port);
		tp = new thread_pool(5);
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

	shared_thread start_handler_proxy(cluster::role role, cluster::state state) {
		s->listen(port);
		cluster::node n = cl->set_node("localhost", port, role, state);
		shared_thread t = tp->get(n.node_thread_type);
		handler_proxy* h = new handler_proxy(t, cl, "localhost", port);
		t->trigger(h, true, false);
		return t;
	}

	void proxy_request(shared_thread t, shared_thread_queue q, string response = "") {
		q->sync_ref();
		t->enqueue(q);
		if (cs.size() == 0) {
			cs = s->wait();
		}
		if (response.length() > 0 && cs.size() > 0) {
			cs[0]->writeline(response.c_str());
		}
		q->sync();
	}

	void test_proxy_write_to_master() {
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_active);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");

		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_slave() {
		shared_thread t = start_handler_proxy(cluster::role_slave, cluster::state_active);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");

		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_proxy() {
		shared_thread t = start_handler_proxy(cluster::role_proxy, cluster::state_active);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q);

		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(op::result_none, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_prepare_node() {
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_prepare);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");

		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_ready_node() {
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_ready);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");

		cut_assert_equal_boolean(true, q->is_success());
		cut_assert_equal_int(op::result_stored, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_write_to_down_node() {
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_down);
		s->close();

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q);

		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(op::result_none, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_master() {
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_active);

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q, "VALUE key 0 5\r\nVALUE\r\nEND");

		cut_assert_equal_boolean(true, q->is_success());
		//cut_assert_equal_int(op::result_found, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_slave() {
		shared_thread t = start_handler_proxy(cluster::role_slave, cluster::state_active);

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q, "VALUE key 0 5\r\nVALUE\r\nEND");

		cut_assert_equal_boolean(true, q->is_success());
		//cut_assert_equal_int(op::result_found, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_proxy() {
		shared_thread t = start_handler_proxy(cluster::role_proxy, cluster::state_active);

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q);

		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(op::result_none, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_prepare_node() {
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_prepare);

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q, "VALUE key 0 5\r\nVALUE\r\nEND");

		cut_assert_equal_boolean(true, q->is_success());
		//cut_assert_equal_int(op::result_found, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_ready_node() {
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_ready);

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q, "VALUE key 0 5\r\nVALUE\r\nEND");

		cut_assert_equal_boolean(true, q->is_success());
		//cut_assert_equal_int(op::result_found, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	void test_proxy_read_to_down_node() {
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_down);
		s->close();

		shared_queue_proxy_read q = get_proxy_queue_read();
		proxy_request(t, q);

		cut_assert_equal_boolean(false, q->is_success());
		cut_assert_equal_int(op::result_none, q->get_result());
		cut_assert_equal_int(0, stats_object->get_total_thread_queue());
	}

	// active -> down -> active
	void test_proxy_state_machine_for_node_state() {
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_active);
		log_notice("debug 1", 0);

		shared_queue_proxy_write q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());
		log_notice("debug 2", 0);

		cl->set_node("localhost", port, cluster::role_master, cluster::state_down);
		for (int i = 0; i < cs.size(); i++) {
			cs[i]->close();
		}
		s->close();
		delete s;
		s = NULL;
		log_notice("debug 3", 0);

		q = get_proxy_queue_write();
		proxy_request(t, q);
		cut_assert_equal_boolean(false, q->is_success());
		log_notice("debug 4", 0);

		cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		s = new server();
		s->listen(port);
		cs.clear();
		log_notice("debug 5", 0);

		q = get_proxy_queue_write();
		proxy_request(t, q, "STORED");
		cut_assert_equal_boolean(true, q->is_success());
		log_notice("debug 6", 0);
	}

	// proxy -> master
	void test_proxy_state_machine_when_node_role_going_into_master_from_proxy() {
		shared_thread t = start_handler_proxy(cluster::role_proxy, cluster::state_active);

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
		shared_thread t = start_handler_proxy(cluster::role_proxy, cluster::state_active);

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
		shared_thread t = start_handler_proxy(cluster::role_slave, cluster::state_active);

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
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_active);

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
		shared_thread t = start_handler_proxy(cluster::role_master, cluster::state_active);

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
		shared_thread t = start_handler_proxy(cluster::role_slave, cluster::state_active);

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
