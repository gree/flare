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
 *	test_cluster_replication.cc
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 */

#include "app.h"
#include "stats.h"
#include "cluster.h"
#include "cluster_replication.h"
#include "key_resolver_modular.h"
#include "server.h"
#include "thread.h"
#include "thread_handler.h"
#include "thread_pool.h"

#include "mock_cluster.h"
#include "mock_storage.h"
#include "mock_op_proxy_write.h"
#include "connection_iostream.h"

#include <cppcutter.h>

using namespace std;
using namespace gree::flare;

namespace test_cluster_replication {
	class handler_async_response : public thread_handler {
		public:
			bool							wait;
		private:
			server*						_server;
			mock_storage*			_storage;
		public:
			handler_async_response(shared_thread t, server* s, mock_storage* storage):
					thread_handler(t) {
				this->wait = false;
				this->_server = s;
				this->_storage = storage;
			}

			~handler_async_response() {
			}

			virtual int run() {
				vector<shared_connection_tcp> cs;
				while (!this->_thread->is_shutdown_request()) {
					if (cs.size() <= 0 || !cs[0]->is_available()) {
						cs = this->_server->wait();
					}

					if (wait) {
						long t = (rand() % 30 + 50) * 1000; // 50 ~ 80 msecs
						usleep(t);
					}

					if (cs.size() > 0 && cs[0]->is_available()) {
						char *p, *q;
						if (cs[0]->readline(&p) <= 0) {
							return 0;
						}

						storage::entry e;
						e.parse(p + 4, storage::parse_type_set);
						delete[] p;

						if (cs[0]->readline(&q) <= 0) {
							return 0;
						}

						shared_byte data(new uint8_t[e.size]);
						memcpy(data.get(), q, e.size);
						delete[] q;

						e.data = data;
						storage::result r;
						this->_storage->set(e, r);

						cs[0]->writeline("STORED");
					}
				}
				return 0;
			}
	};

	void sa_usr1_handler(int sig) {
		// just ignore
	}

	int										port;
	mock_cluster*					cl;
	mock_storage*					st;
	server*								s;
	thread_pool*					tp;
	vector<shared_connection_tcp>		cs;
	cluster_replication*	cl_repl;
	mock_storage*					local_storage;
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
		st = new mock_storage("", 0, 0);
		st->open();

		cl_repl = new cluster_replication(tp);
		local_storage = new mock_storage("", 0 , 0);
	}

	void teardown() {
		for (int i = 0; i < cs.size(); i++) {
			cs[i]->close();
		}
		tp->shutdown();
		cs.clear();
		s->close();
		st->close();
		delete cl_repl;
		delete tp;
		delete s;
		delete st;
		delete cl;
		delete local_storage;
		delete stats_object;

		if (sigaction(SIGUSR1, &prev_sigusr1_action, NULL) < 0) {
			log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
			return;
		}
	}

	void prepare_storage(int item_num, int version) {
		for (int i = 0; i < item_num; i++) {
			string key = "key" + boost::lexical_cast<string>(i);
			string data = "VALUE";
			st->set_helper(key, data.c_str(), 0, version);
		}
	}

	storage::entry get_entry(string firstline, storage::parse_type type, string value) {
		storage::entry e;
		e.parse(firstline.c_str(), type);
		shared_byte data(new uint8_t[e.size]);
		memcpy(data.get(), value.c_str(), e.size);
		e.data = data;
		return e;
	}

	void start_cluster_replication(string host, int _port, int concurrency, bool wait = true, bool skip_dump = false) {
		cut_assert_equal_int(0, cl_repl->start(host, _port, concurrency, st, cl, skip_dump));
		if (s->listen(port) < 0) {
			cut_fail("failed to listen port (=%d)", port);
		}
		if (wait) {
			cs = s->wait();
		}
	}

	void assert_variable(string server_name, int server_port, int concurrency, bool sync = false) {
		cut_assert_equal_string(server_name.c_str(), cl_repl->get_server_name().c_str());
		cut_assert_equal_int(server_port, cl_repl->get_server_port());
		cut_assert_equal_int(concurrency, cl_repl->get_concurrency());
		cut_assert_equal_boolean(sync, cl_repl->get_sync());
	}

	void assert_state(bool started, bool dump) {
		cut_assert_equal_boolean(started, cl_repl->is_started());
		thread_pool::local_map m_cl = tp->get_active(thread_pool::thread_type_cluster_replication);
		if (started) {
			cut_assert_equal_int(cl_repl->get_concurrency(), m_cl.size());
		} else {
			cut_assert_equal_int(0, m_cl.size());
		}
		thread_pool::local_map m_dump = tp->get_active(thread_pool::thread_type_dump_replication);
		if (dump) {
			cut_assert_equal_int(1, m_dump.size());
		} else {
			cut_assert_equal_int(0, m_dump.size());
		}
	}

	void assert_queue_size(int exp) {
		int queue_size = 0;
		thread_pool::local_map m = tp->get_active(thread_pool::thread_type_cluster_replication);
		for (thread_pool::local_map::iterator it = m.begin(); it != m.end(); it++) {
			queue_size += it->second->get_thread_info().queue_size;
		}
		cut_assert_equal_int(exp, queue_size);
	}

	void assert_queue_size(int max, int min) {
		int queue_size = 0;
		thread_pool::local_map m = tp->get_active(thread_pool::thread_type_cluster_replication);
		for (thread_pool::local_map::iterator it = m.begin(); it != m.end(); it++) {
			queue_size += it->second->get_thread_info().queue_size;
		}
		cut_assert_true(max >= queue_size && min <= queue_size);
	}

	void test_default_value() {
		assert_variable("", 0, 0);
		assert_state(false, false);
	}

	void test_set_sync() {
		cut_assert_equal_boolean(false, cl_repl->get_sync());
		cut_assert_equal_int(0, cl_repl->set_sync(true));
		cut_assert_equal_boolean(true, cl_repl->get_sync());
		cut_assert_equal_int(0, cl_repl->set_sync(false));
		cut_assert_equal_boolean(false, cl_repl->get_sync());
	}

	void test_start_success_when_master() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		st->iter_wait = 1 * 100 * 1000; // 100 msecs

		// execute
		start_cluster_replication("localhost", port, 3);

		// assert
		assert_variable("localhost", port, 3);
		assert_state(true, true);
		usleep(200 * 1000);  // waiting for dump replication completed
		assert_state(true, false);
	}

	void test_start_success_when_slave() {
		// prepare
		cluster::node master = cl->set_node("dummy", port + 1, cluster::role_master, cluster::state_active);
		cluster::node slave = cl->set_node("localhost", port, cluster::role_slave, cluster::state_active);
		cluster::node slaves[] = {slave};
		cl->set_partition(0, master, slaves, 1);
		st->iter_wait = 1 * 100 * 1000; // 100 msecs

		// execute
		start_cluster_replication("localhost", port, 3);

		// assert
		assert_variable("localhost", port, 3);
		assert_state(true, true);
		usleep(200 * 1000);  // waiting for dump replication completed
		assert_state(true, false);
	}

	void test_start_success_with_dump() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		prepare_storage(5, 1);

		// execute
		start_cluster_replication("localhost", port, 1, false);
		assert_variable("localhost", port, 1);
		assert_state(true, true);

		for (int i = 0; i < 2; i++) {
			shared_thread t = tp->get(thread_pool::thread_type_request);
			handler_async_response* h = new handler_async_response(t, s, local_storage);
			t->trigger(h, true, false);
		}

		bool no_request = false;
		usleep(1000 * 1000);  // waiting for dump replication completed
		cut_assert_equal_int(5, local_storage->count());
		for (int i = 0; i < 5; i++) {
			string key = "key" + boost::lexical_cast<string>(i);
			storage::entry e;
			local_storage->get_helper(key, e);
			cut_assert_equal_string(key.c_str(), e.key.c_str());
			cut_assert_equal_int(0, e.flag);
			cut_assert_equal_int(5, e.size);
			cut_assert_equal_int(1, e.version);
			cut_assert_equal_memory("VALUE", 5, (const char*)e.data.get(), 5);
		}
		usleep(100 * 1000);
		assert_state(true, false);
	}

	void test_start_success_without_dump() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		prepare_storage(5, 1);

		// execute
		start_cluster_replication("localhost", port, 1, false, true);
		assert_variable("localhost", port, 1);
		assert_state(true, false);
	}

	void test_start_failure_when_proxy() {
		// prepare
		cl->set_node("localhost", port, cluster::role_proxy, cluster::state_active);

		// execute
		cut_assert_equal_int(-1, cl_repl->start("localhost", port, 1, st, cl));

		// assert
		assert_variable("", 0, 0);
		assert_state(false, false);
	}

	void test_start_failure_with_no_concurrency() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);

		// execute
		cut_assert_equal_int(-1, cl_repl->start("localhost", port, 0, st, cl));

		// assert
		assert_variable("", 0, 0);
		assert_state(false, false);
	}

	void test_start_failure_in_started_state() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		st->iter_wait = 1 * 100 * 1000; // 100 msecs
		start_cluster_replication("localhost", port, 3);

		// execute
		cut_assert_equal_int(-1, cl_repl->start("localhost", port, 4, st, cl));

		// assert
		assert_variable("localhost", port, 3);
		assert_state(true, true);
	}

	void test_stop_success_in_stated_state() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		st->iter_wait = 1 * 100 * 1000; // 200 msecs
		start_cluster_replication("localhost", port, 3);
		assert_variable("localhost", port, 3);
		assert_state(true, true);

		// execute
		cut_assert_equal_int(0, cl_repl->stop());
		usleep(100 * 1000);  // waiting for shutdown of asynchronous replication threads.

		// assert
		assert_variable("", 0, 0);
		assert_state(false, false);
	}

	void test_stop_sucess_in_not_started_state() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);

		// execute
		cut_assert_equal_int(0, cl_repl->stop());

		// assert
		assert_variable("", 0, 0);
		assert_state(false, false);
	}

	void test_on_pre_proxy_read_success() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		start_cluster_replication("localhost", port, 3);
		assert_variable("localhost", port, 3);

		// execute
		usleep(100 * 1000);
		shared_connection c(new connection_sstream(" TEST"));
		op_get op(c, cl, st);
		cut_assert_equal_int(0, cl_repl->on_pre_proxy_read(&op));
	}

	void test_on_pre_proxy_write_success() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		start_cluster_replication("localhost", port, 3);
		assert_variable("localhost", port, 3);

		// execute
		usleep(100 * 1000);
		shared_connection c(new connection_sstream(" TEST 0 0 5\r\nVALUE\r\n"));
		op_set op(c, cl, st);
		cut_assert_equal_int(0, cl_repl->on_pre_proxy_write(&op));
	}

	void test_on_post_proxy_write_success_when_async() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		st->iter_wait = 1 * 100 * 1000; // 100 msecs
		start_cluster_replication("localhost", port, 3, false);
		assert_variable("localhost", port, 3);
		assert_state(true, true);

		for (int i = 0; i < 4; i++) {
			shared_thread t = tp->get(thread_pool::thread_type_request);
			handler_async_response* h = new handler_async_response(t, s, local_storage);
			t->trigger(h, true, false);
		}

		// execute
		usleep(100 * 1000);
		for (int i = 0; i < 5; i++) {
			shared_connection c(new connection_sstream("dummy"));
			mock_op_proxy_write op(c, cl, st);
			string key = "key" + boost::lexical_cast<string>(i);
			storage::entry e = get_entry(" " + key + " 0 0 5 3", storage::parse_type_set, "VALUE");
			op.set_entry(e);
			cut_assert_equal_int(0, cl_repl->on_post_proxy_write(&op));
		}

		// assert
		assert_queue_size(5, 0);
		usleep(200 * 1000);  // waiting for queue proceeded
		assert_queue_size(0);
		cut_assert_equal_int(5, local_storage->count());
		for (int i = 0; i < 5; i++) {
			string key = "key" + boost::lexical_cast<string>(i);
			storage::entry e;
			local_storage->get_helper(key, e);
			cut_assert_equal_string(key.c_str(), e.key.c_str());
			cut_assert_equal_int(0, e.flag);
			cut_assert_equal_int(5, e.size);
			cut_assert_equal_int(3, e.version);
			cut_assert_equal_memory("VALUE", 5, (const char*)e.data.get(), 5);
		}

		usleep(100 * 1000);
		assert_queue_size(0);
		assert_state(true, false);
	}

	void test_on_post_proxy_write_success_with_sync() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		cl_repl->set_sync(true);
		st->iter_wait = 1 * 100 * 1000; // 100 msecs
		start_cluster_replication("localhost", port, 3, false);
		assert_variable("localhost", port, 3, true);
		assert_state(true, true);

		for (int i = 0; i < 4; i++) {
			shared_thread t = tp->get(thread_pool::thread_type_request);
			handler_async_response* h = new handler_async_response(t, s, local_storage);
			t->trigger(h, true, false);
		}

		// execute
		usleep(100 * 1000);
		for (int i = 0; i < 5; i++) {
			shared_connection c(new connection_sstream("dummy"));
			mock_op_proxy_write op(c, cl, st);
			string key = "key" + boost::lexical_cast<string>(i);
			storage::entry e = get_entry(" " + key + " 0 0 5 3", storage::parse_type_set, "VALUE");
			op.set_entry(e);

			// assert
			cut_assert_equal_int(0, cl_repl->on_post_proxy_write(&op));
			assert_queue_size(0);
			storage::entry _e;
			local_storage->get_helper(key, _e);
			cut_assert_equal_string(key.c_str(), _e.key.c_str());
			cut_assert_equal_int(0, _e.flag);
			cut_assert_equal_int(5, _e.size);
			cut_assert_equal_int(3, _e.version);
			cut_assert_equal_memory("VALUE", 5, (const char*)_e.data.get(), 5);
		}

		// assert
		usleep(100 * 1000);  // waiting for queue proceeded
		assert_queue_size(0);
		assert_state(true, false);
	}

	void test_on_post_proxy_write_success_with_dump() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		//st->iter_wait = 1 * 10 * 1000; // 100 msecs
		prepare_storage(5, 1);

		// execute
		start_cluster_replication("localhost", port, 3, false);
		assert_variable("localhost", port, 3);
		assert_state(true, true);

		for (int i = 0; i < 4; i++) {
			shared_thread t = tp->get(thread_pool::thread_type_request);
			handler_async_response* h = new handler_async_response(t, s, local_storage);
			t->trigger(h, true, false);
			h->wait = true;
		}

		usleep(100 * 1000);
		for (int i = 0; i < 5; i++) {
			shared_connection c(new connection_sstream("dummy"));
			mock_op_proxy_write op(c, cl, st);
			string key = "key" + boost::lexical_cast<string>(i);
			storage::entry e = get_entry(" " + key + " 0 0 5 3", storage::parse_type_set, "VALUE");
			op.set_entry(e);
			cut_assert_equal_int(0, cl_repl->on_post_proxy_write(&op));
		}

		usleep(500 * 1000);  // waiting for replication completed
		cut_assert_equal_int(5, local_storage->count());
		for (int i = 0; i < 5; i++) {
			string key = "key" + boost::lexical_cast<string>(i);
			storage::entry e;
			local_storage->get_helper(key, e);
			cut_assert_equal_string(key.c_str(), e.key.c_str());
			cut_assert_equal_int(0, e.flag);
			cut_assert_equal_int(5, e.size);
			cut_assert_equal_int(3, e.version);
			cut_assert_equal_memory("VALUE", 5, (const char*)e.data.get(), 5);
		}
		usleep(100 * 1000);
		assert_state(true, false);
	}

	void test_on_post_proxy_write_failure_in_not_started_state() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);

		// execute
		shared_connection c(new connection_sstream(" TEST 0 0 5\r\nVALUE\r\n"));
		op_set op(c, cl, st);
		cut_assert_equal_int(-1, cl_repl->on_post_proxy_write(&op));
	}

	void test_on_post_proxy_write_invalid_destination() {
		// prepare
		cluster::node master = cl->set_node("localhost", port, cluster::role_master, cluster::state_active);
		cl->set_partition(0, master);
		cut_assert_equal_int(0, cl_repl->start("localhost", port, 1, st, cl));
		sleep(7);  // waiting for connection failed

		// execute
		shared_connection c(new connection_sstream(" TEST 0 0 5\r\nVALUE\r\n"));
		mock_op_proxy_write op(c, NULL, NULL);
		cut_assert_equal_int(-1, cl_repl->on_post_proxy_write(&op));
	}
}
