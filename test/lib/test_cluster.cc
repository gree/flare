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
 *	test_cluster.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>
#include "op_set.h"
#include "op_get.h"

#include <fstream>

#include <app.h>
#include <cluster.h>
#include <coordinator_factory.h>
#include <stats.h>

using namespace gree::flare;


namespace test_cluster
{
	void sa_usr1_handler(int sig) {
		// just ignore
	}

	const std::string tmp_dir = "tmp";
	AtomicCounter *thread_idx;
	thread_pool *req_tp;
	thread_pool *other_tp;
	struct sigaction prev_sigusr1_action;

	void setup() {
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = sa_usr1_handler;
		if (sigaction(SIGUSR1, &sa, &prev_sigusr1_action) < 0) {
			log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
		}

		thread_idx = new AtomicCounter(1);
		req_tp = new thread_pool(5, 128, thread_idx);
		other_tp = new thread_pool(5, 128, thread_idx);

		mkdir(tmp_dir.c_str(), 0700);

		singleton<logger>::instance().open("test-cluster", "local5", false);
		stats_object = new stats();
		stats_object->startup();
	}

	void teardown() {
		req_tp->shutdown();
		delete req_tp;
		other_tp->shutdown();
		delete other_tp;
		delete thread_idx;
		delete stats_object;
		singleton<logger>::instance().close();
		cut_remove_path(tmp_dir.c_str(), NULL);

		if (sigaction(SIGUSR1, &prev_sigusr1_action, NULL) < 0) {
			log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
			return;
		}
	}

	struct cluster_test : public cluster
	{
		cluster_test(std::string data_dir):
			cluster(req_tp, other_tp, "localhost", 11211) {
			char cwd[PATH_MAX];
			if (getcwd(cwd, sizeof(cwd)) != cwd) {
				log_err("getcwd() failed.", 1);
				exit(1);
			}

			char *uri = getenv("TEST_CLUSTER_INDEX_DB");

			coordinator *coord = NULL;
			if (uri != NULL) {
				coord = this->_coordinator_factory.create_coordinator(uri, "myname");
			}
			if (coord == NULL) {
				coord = this->_coordinator_factory.create_coordinator("file://"+std::string(cwd)+"/"+data_dir, "myname");
			}

			key_resolver::type t;
			key_resolver::type_cast("modular", t);
			this->startup_index(coord, t, 1, 65536);
		}
		~cluster_test() {
			this->_coordinator->set_update_handler(NULL);
			this->_coordinator_factory.destroy_coordinator(this->_coordinator);
			this->_coordinator = NULL;
		}

		coordinator_factory _coordinator_factory;
		std::string _tmp_data_dir;
		using cluster::_load;
		using cluster::_save;
		using cluster::_node_map;
		using cluster::_thread_type;
		using cluster::_type;
	};

	void test_deserialization_skip() {
		cluster_test cluster(".");
		cut_assert_equal_int(0, cluster._load());
		cut_assert_equal_int(0, cluster._node_map.size());
		cut_assert_equal_int(16, cluster._thread_type);
	}

	void test_deserialization_ok() {
		// Initialization
		const std::string _tmp_dir = tmp_dir + std::string("/cdo");
		mkdir(_tmp_dir.c_str(), 0700);
		std::string flare_xml_contents = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>\n"
			"<!DOCTYPE boost_serialization>\n"
			"<boost_serialization signature=\"serialization::archive\" version=\"7\">\n"
			"<node_map_version>1</node_map_version>\n"
			"<node_map class_id=\"0\" tracking_level=\"0\" version=\"0\">\n"
			"	<count>1</count>\n"
			"	<item_version>0</item_version>\n"
			"	<item class_id=\"1\" tracking_level=\"0\" version=\"0\">\n"
			"		<first>172.16.65.242:13301</first>\n"
			"		<second class_id=\"2\" tracking_level=\"0\" version=\"0\">\n"
			"			<node_server_name>172.16.65.242</node_server_name>\n"
			"			<node_server_port>13301</node_server_port>\n"
			"			<node_role>0</node_role>\n"
			"			<node_state>1</node_state>\n"
			"			<node_partition>2</node_partition>\n"
			"			<node_balance>3</node_balance>\n"
			"			<node_thread_type>4</node_thread_type>\n"
			"		</second>\n"
			"	</item>\n"
			"</node_map>\n"
			"<thread_type>5</thread_type>\n"	// Wrong: thread_type == item.node_thread_type
			"</boost_serialization>\n";
		std::ofstream flare_xml_file(std::string(_tmp_dir + std::string("/flare.xml")).c_str());
		flare_xml_file << flare_xml_contents;
		flare_xml_file.close();
		// Test
		cluster_test cluster(_tmp_dir);
		cut_assert_equal_int(0, cluster._load());
		cut_assert_equal_int(1, cluster._node_map.size());
		cut_assert_equal_string("172.16.65.242:13301", cluster._node_map.begin()->first.c_str());
		cut_assert_equal_string("172.16.65.242", cluster._node_map.begin()->second.node_server_name.c_str());
		cut_assert_equal_int(13301, cluster._node_map.begin()->second.node_server_port);
		cut_assert_equal_int(0, cluster._node_map.begin()->second.node_role);
		cut_assert_equal_int(1, cluster._node_map.begin()->second.node_state);
		cut_assert_equal_int(2, cluster._node_map.begin()->second.node_partition);
		cut_assert_equal_int(3, cluster._node_map.begin()->second.node_balance);
		cut_assert_equal_int(4, cluster._node_map.begin()->second.node_thread_type);
		cut_assert_equal_int(5, cluster._thread_type);
	}

	void test_deserialization_wrong_thread_type() {
		// Initialization
		const std::string _tmp_dir = tmp_dir + std::string("/thread_type");
		mkdir(_tmp_dir.c_str(), 0700);
		std::string flare_xml_contents = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>\n"
			"<!DOCTYPE boost_serialization>\n"
			"<boost_serialization signature=\"serialization::archive\" version=\"7\">\n"
			"<node_map_version>1</node_map_version>\n"
			"<node_map class_id=\"0\" tracking_level=\"0\" version=\"0\">\n"
			"	<count>1</count>\n"
			"	<item_version>0</item_version>\n"
			"	<item class_id=\"1\" tracking_level=\"0\" version=\"0\">\n"
			"		<first>172.16.65.242:13301</first>\n"
			"		<second class_id=\"2\" tracking_level=\"0\" version=\"0\">\n"
			"			<node_server_name>172.16.65.242</node_server_name>\n"
			"			<node_server_port>13301</node_server_port>\n"
			"			<node_role>1</node_role>\n"
			"			<node_state>0</node_state>\n"
			"			<node_partition>0</node_partition>\n"
			"			<node_balance>1</node_balance>\n"
			"			<node_thread_type>80</node_thread_type>\n"
			"		</second>\n"
			"	</item>\n"
			"</node_map>\n"
			"<thread_type>80</thread_type>\n"	// Wrong: thread_type == item.node_thread_type
			"</boost_serialization>\n";
		std::ofstream flare_xml_file(std::string(_tmp_dir + std::string("/flare.xml")).c_str());
		flare_xml_file << flare_xml_contents;
		flare_xml_file.close();
		// Test
		cluster_test cluster(_tmp_dir);
		cut_assert_equal_int(-1, cluster._load());
	}

	void test_version_for_index()
	{
		// Initialization
		const std::string _tmp_dir = tmp_dir + std::string("/version_for_index");
		mkdir(_tmp_dir.c_str(), 0700);
		// Test
		cluster_test cluster(_tmp_dir);
		uint64_t ver = 0;
		ver = cluster.get_node_map_version();
		cppcut_assert_equal(ver, cluster.get_node_map_version());
		if (cluster.add_node("localhost", 12121) < 0) {
			cppcut_assert_equal(ver, cluster.get_node_map_version());
		} else {
			ver++;
			cppcut_assert_equal(ver, cluster.get_node_map_version());
		}
		cluster.down_node("localhost", 12121);
		ver = cluster.get_node_map_version();
		if (cluster.remove_node("localhost", 12121) < 0) {
			cppcut_assert_equal(ver, cluster.get_node_map_version());
		} else {
			ver++;
			cppcut_assert_equal(ver, cluster.get_node_map_version());
		}
	}

	void test_version_for_data()
	{
		// Initialization
		const std::string _tmp_dir = tmp_dir + std::string("/version_for_data");
		mkdir(_tmp_dir.c_str(), 0700);
		// Test
		cluster_test cluster(_tmp_dir);
		uint64_t ver = cluster.get_node_map_version();
		vector<cluster::node> v;
		ver += 10;
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ver));    // allow higher version
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ver));    // allow the same version
		cppcut_assert_equal(-1, cluster.reconstruct_node(v, ver-1)); // deny lower version
	}

	// shared flags between the test threads: atomic loads / stores (no data
	// race; review of 10f5f57)
	static int ld(const int* p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }
	static void st(int* p, int v) { __atomic_store_n(p, v, __ATOMIC_SEQ_CST); }
	static long ldl(const long* p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }

	struct swap_arg {
		cluster_test* c;
		uint64_t ver;
		int done;
	};

	static void* swap_map(void* a) {
		swap_arg* x = static_cast<swap_arg*>(a);
		vector<cluster::node> v;
		x->c->reconstruct_node(v, x->ver);
		st(&x->done, 1);
		return NULL;
	}

	static bool wait_flag(const int* f, int ms) {
		for (int i = 0; i < ms / 10 && !ld(f); i++) {
			usleep(10 * 1000);
		}
		return ld(f) != 0;
	}

	// NODE-OPS-LOSSLESS-PLAN L1: a write in its write section (role decided,
	// applied, forwards not yet queued) holds a map swap back until it leaves;
	// a nested entry on the same thread does not lock again (no self-deadlock)
	void test_map_swap_waits_for_a_write_in_its_section()
	{
		const std::string _tmp_dir = tmp_dir + std::string("/write_section");
		mkdir(_tmp_dir.c_str(), 0700);
		cluster_test cluster(_tmp_dir);
		swap_arg a;
		a.c = &cluster;
		a.ver = cluster.get_node_map_version() + 10;
		st(&a.done, 0);
		cluster.write_section_enter();
		cluster.write_section_enter();		// nested: depth 2, one lock
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, swap_map, &a));
		usleep(300 * 1000);
		cut_assert_equal_int(0, ld(&a.done), cut_message("the map was swapped while a write was in its section"));
		cluster.write_section_leave();		// depth 1: still held
		usleep(300 * 1000);
		cut_assert_equal_int(0, ld(&a.done), cut_message("the map was swapped after the inner leave"));
		cluster.write_section_leave();		// released
		cut_assert_true(wait_flag(&a.done, 5000));
		pthread_join(t, NULL);
		cppcut_assert_equal(a.ver, cluster.get_node_map_version());
		// an unbalanced leave is ignored
		cluster.write_section_leave();
		cluster.write_section_enter();
		cluster.write_section_leave();
	}

	struct probe_arg {
		cluster_test* c;
		int refused;			// a new write was refused while the swap waited
		int entered_while_waiting;
		int stop;
	};

	// a NEW write (another thread, no section held) tries to enter while a
	// write holds the section and a swap waits; it records whether it was
	// refused (the swap is preferred) or let in
	static void* probe_new_write(void* a) {
		probe_arg* x = static_cast<probe_arg*>(a);
		for (int i = 0; i < 200 && !ld(&x->stop); i++) {
			if (x->c->write_section_try_enter()) {
				x->c->write_section_leave();
			} else {
				st(&x->refused, 1);
				break;
			}
			usleep(10 * 1000);
		}
		return NULL;
	}

	// The map swap is preferred over new writes (review of 8d64aaf / 10f5f57):
	// while one write holds the section and a swap is QUEUED, a new write must
	// be refused (try-enter fails) — with a reader-preferring lock it is let
	// in, and a steady stream of writes can hold the swap off indefinitely.
	// The probe keeps trying for up to 2 s, so it is not a guess about when
	// the swap queued: it is refused only once the swap is queued, and never
	// on a reader-preferring lock.
	void test_a_waiting_map_swap_is_preferred_over_a_new_write()
	{
		const std::string _tmp_dir = tmp_dir + std::string("/write_section_pref");
		mkdir(_tmp_dir.c_str(), 0700);
		cluster_test cluster(_tmp_dir);
		cluster.write_section_enter();			// write 1 holds the section
		swap_arg a;
		a.c = &cluster;
		a.ver = cluster.get_node_map_version() + 10;
		st(&a.done, 0);
		pthread_t ts;
		cut_assert_equal_int(0, pthread_create(&ts, NULL, swap_map, &a));
		probe_arg p;
		p.c = &cluster;
		st(&p.refused, 0);
		st(&p.entered_while_waiting, 0);
		st(&p.stop, 0);
		pthread_t tp;
		cut_assert_equal_int(0, pthread_create(&tp, NULL, probe_new_write, &p));
		pthread_join(tp, NULL);
		const int refused = ld(&p.refused);
		const int swapped_early = ld(&a.done);
		cluster.write_section_leave();			// write 1 ends: the swap goes
		cut_assert_true(wait_flag(&a.done, 5000), cut_message("the swap did not complete after the write left"));
		pthread_join(ts, NULL);
		cut_assert_equal_int(0, swapped_early, cut_message("the swap completed while a write held the section"));
		cut_assert_equal_int(1, refused, cut_message("a new write kept entering the section for 2 s while a map swap was queued (the lock prefers readers)"));
	}

	struct reader_arg {
		cluster_test* c;
		int stop;
		long entries;
	};

	static void* steady_writer(void* a) {
		reader_arg* x = static_cast<reader_arg*>(a);
		while (!ld(&x->stop)) {
			x->c->write_section_enter();
			usleep(300);
			x->c->write_section_leave();
			__atomic_add_fetch(&x->entries, 1, __ATOMIC_SEQ_CST);
		}
		return NULL;
	}

	// liveness under a steady write load: a map swap gets the section within
	// a bound. A smoke test only: on a reader-preferring lock it passed once
	// and failed once with this load, so the preference itself is shown by
	// the deterministic test above
	void test_map_swap_is_not_starved_by_a_steady_write_load()
	{
		const std::string _tmp_dir = tmp_dir + std::string("/write_section_steady");
		mkdir(_tmp_dir.c_str(), 0700);
		cluster_test cluster(_tmp_dir);
		const int n = 4;
		reader_arg ra[n];
		pthread_t rt[n];
		for (int i = 0; i < n; i++) {
			ra[i].c = &cluster;
			st(&ra[i].stop, 0);
			__atomic_store_n(&ra[i].entries, 0L, __ATOMIC_SEQ_CST);
			cut_assert_equal_int(0, pthread_create(&rt[i], NULL, steady_writer, &ra[i]));
		}
		usleep(200 * 1000);
		swap_arg a;
		a.c = &cluster;
		a.ver = cluster.get_node_map_version() + 10;
		st(&a.done, 0);
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, swap_map, &a));
		const bool done = wait_flag(&a.done, 2000);
		long before = 0;
		for (int i = 0; i < n; i++) {
			before += ldl(&ra[i].entries);
		}
		for (int i = 0; i < n; i++) {
			st(&ra[i].stop, 1);
		}
		for (int i = 0; i < n; i++) {
			pthread_join(rt[i], NULL);
		}
		pthread_join(t, NULL);
		cut_assert_true(done, cut_message("the map swap did not get the write section within 2 s under a steady write load (%ld writes)", before));
		cut_assert(before > 100, cut_message("the write load was not steady (%ld writes)", before));
		cppcut_assert_equal(a.ver, cluster.get_node_map_version());
	}

	// a section held on one cluster instance does not let a nested entry on
	// another instance skip that instance's lock
	void test_write_section_depth_is_per_cluster_instance()
	{
		const std::string d1 = tmp_dir + std::string("/write_section_i1");
		const std::string d2 = tmp_dir + std::string("/write_section_i2");
		mkdir(d1.c_str(), 0700);
		mkdir(d2.c_str(), 0700);
		cluster_test c1(d1);
		cluster_test c2(d2);
		c1.write_section_enter();
		c2.write_section_enter();		// another instance: takes c2's lock
		swap_arg a;
		a.c = &c2;
		a.ver = c2.get_node_map_version() + 10;
		st(&a.done, 0);
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, swap_map, &a));
		usleep(300 * 1000);
		cut_assert_equal_int(0, ld(&a.done), cut_message("c2's map was swapped while a write was in c2's section"));
		c2.write_section_leave();
		cut_assert_true(wait_flag(&a.done, 5000));
		pthread_join(t, NULL);
		c1.write_section_leave();
	}

	cluster::node mk(const char* name, int port, cluster::role r, cluster::state st, int part) {
		cluster::node n;
		n.node_server_name = name;
		n.node_server_port = port;
		n.node_role = r;
		n.node_state = st;
		n.node_partition = part;
		n.node_balance = 0;
		n.node_thread_type = 16;
		return n;
	}

	// CI 37572870090: a restarted replica, still building its copy, accepted a
	// map that (from a stale view) said it was active, became active locally
	// and re-announced an activation for a copy that was not complete. While
	// its own reconstruction runs and its activation was not acknowledged, a
	// map saying active leaves it prepare; the echo of an acknowledged
	// activation is accepted.
	void test_stale_active_map_while_reconstructing_stays_prepare()
	{
		const std::string _tmp_dir = tmp_dir + std::string("/stale_active");
		mkdir(_tmp_dir.c_str(), 0700);
		cluster_test cluster(_tmp_dir);
		cluster._type = cluster::type_node;		// the self-node rules apply to a node
		uint64_t ver = cluster.get_node_map_version() + 10;
		vector<cluster::node> v;
		v.push_back(mk("master", 12121, cluster::role_master, cluster::state_active, 0));
		v.push_back(mk("localhost", 11211, cluster::role_slave, cluster::state_prepare, 0));
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ver));
		stats_object->reconstruction_begin();
		v[1].node_state = cluster::state_active;
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ++ver));
		cut_assert_equal_int(cluster::state_prepare, cluster.get_node("localhost", 11211).node_state);
		// the activation was acknowledged: the map's echo is accepted
		cluster.set_activation_pending(true);
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ++ver));
		cut_assert_equal_int(cluster::state_active, cluster.get_node("localhost", 11211).node_state);
	}

	// a client (or proxied) set of `key` through pre_proxy_write; `sender` is
	// the proxy mark ("" = a client write)
	struct ppw_arg {
		cluster_test* c;
		std::string key;
		std::string sender;
		int result;
		long ms;
		int done;
	};

	static long now_ms() {
		struct timespec ts;
		clock_gettime(CLOCK_MONOTONIC, &ts);
		return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
	}

	static void* run_ppw(void* a) {
		ppw_arg* x = static_cast<ppw_arg*>(a);
		op_set* o = new op_set(shared_connection(), x->c, NULL);
		storage::entry& e = o->get_entry();
		e.key = x->key;
		e.version = 3;
		if (!x->sender.empty()) {
			o->set_proxy(x->sender);
		}
		shared_queue_proxy_write q;
		const long t0 = now_ms();
		x->result = x->c->pre_proxy_write(o, q, 0);
		x->ms = now_ms() - t0;
		delete o;		// leaves the write section of a local apply
		st(&x->done, 1);
		return NULL;
	}

	// W (handover design): the partition's master is master/down (a planned
	// handover's demote step). A client write waits for a map with a master
	// instead of failing; when the map names a master again it is decided
	// from the start. Here the map that ends the wait is the handover's
	// rollback (this node, the master/down placeholder, back to master/active:
	// no role shift, which the test cluster cannot do), so the write is applied
	// here. Every check is made after the thread is joined: an assertion that
	// left the test with the thread still waiting would destroy the cluster
	// under it.
	void test_a_write_waits_for_a_master_while_the_partition_has_none()
	{
		const std::string _tmp_dir = tmp_dir + std::string("/master_wait");
		mkdir(_tmp_dir.c_str(), 0700);
		cluster_test cluster(_tmp_dir);
		cluster._type = cluster::type_node;
		cluster.set_master_wait_ms(5000);
		uint64_t ver = cluster.get_node_map_version() + 10;
		vector<cluster::node> v;
		v.push_back(mk("localhost", 11211, cluster::role_master, cluster::state_down, 0));
		v.push_back(mk("s1", 12121, cluster::role_slave, cluster::state_active, 0));
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ver));
		const uint64_t ok0 = stats_object->get_master_waits_ok();
		ppw_arg a;
		a.c = &cluster;
		a.key = "k";
		a.result = -100;
		st(&a.done, 0);
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, run_ppw, &a));
		usleep(300 * 1000);
		const int done_early = ld(&a.done);
		const int waiting = (int)stats_object->get_writes_waiting_for_master();
		// the rollback map: the master is back
		v[0] = mk("localhost", 11211, cluster::role_master, cluster::state_active, 0);
		const int rc = cluster.reconstruct_node(v, ++ver);
		const bool finished = wait_flag(&a.done, 5000);
		if (!finished) {
			// end the wait before leaving (the cluster is on this stack)
			cluster.set_master_wait_ms(0);
		}
		pthread_join(t, NULL);
		cut_assert_equal_int(0, done_early, cut_message("the write did not wait for a master"));
		cut_assert_equal_int(1, waiting);
		cppcut_assert_equal(0, rc);
		cut_assert_true(finished);
		cut_assert_equal_int(cluster::proxy_request_continue, a.result);
		cut_assert(a.ms >= 250, cut_message("answered after %ld ms", a.ms));
		cut_assert_equal_int(0, (int)stats_object->get_writes_waiting_for_master());
		cut_assert_equal_int(1, (int)(stats_object->get_master_waits_ok() - ok0));
	}

	// ... and fails with the partition error when no master comes within the
	// wait (the client hears an error, as before W)
	void test_a_write_waiting_for_a_master_fails_at_the_bound()
	{
		const std::string _tmp_dir = tmp_dir + std::string("/master_wait_bound");
		mkdir(_tmp_dir.c_str(), 0700);
		cluster_test cluster(_tmp_dir);
		cluster._type = cluster::type_node;
		cluster.set_master_wait_ms(400);
		uint64_t ver = cluster.get_node_map_version() + 10;
		vector<cluster::node> v;
		v.push_back(mk("old", 12121, cluster::role_master, cluster::state_down, 0));
		v.push_back(mk("localhost", 11211, cluster::role_slave, cluster::state_active, 0));
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ver));
		const uint64_t timeout0 = stats_object->get_master_waits_timeout();
		ppw_arg a;
		a.c = &cluster;
		a.key = "k";
		st(&a.done, 0);
		run_ppw(&a);
		cut_assert_equal_int(cluster::proxy_request_error_partition, a.result);
		cut_assert(a.ms >= 350 && a.ms < 2000, cut_message("failed after %ld ms (bound 400)", a.ms));
		cut_assert_equal_int(1, (int)(stats_object->get_master_waits_timeout() - timeout0));
		// without W (0) it fails at once, as before
		cluster.set_master_wait_ms(0);
		run_ppw(&a);
		cut_assert_equal_int(cluster::proxy_request_error_partition, a.result);
		cut_assert(a.ms < 200, cut_message("W off still waited %ld ms", a.ms));
	}

	struct ppr_arg {
		cluster_test* c;
		std::string key;
		int result;
		long ms;
		int done;
	};

	static void* run_ppr(void* a) {
		ppr_arg* x = static_cast<ppr_arg*>(a);
		op_get o(shared_connection(), x->c, NULL);
		storage::entry e;
		e.key = x->key;
		shared_queue_proxy_read q;
		const long t0 = now_ms();
		x->result = x->c->pre_proxy_read(&o, e, NULL, q);
		x->ms = now_ms() - t0;
		st(&x->done, 1);
		return NULL;
	}

	// W for reads (998dc30 copy-identity 11): while the map names no master
	// for the partition (a handover's demote map: this node the master/down
	// placeholder) a read waits for the next map instead of failing as "no
	// partition" (answered as a miss). The map that ends the wait is the
	// rollback (this node master/active again), so the read is decided from
	// the start and served here (a forward needs the transport the test
	// cluster lacks). Checks after the join, as for the write.
	void test_a_read_waits_for_a_master_while_the_partition_has_none()
	{
		const std::string _tmp_dir = tmp_dir + std::string("/read_master_wait");
		mkdir(_tmp_dir.c_str(), 0700);
		cluster_test cluster(_tmp_dir);
		cluster._type = cluster::type_node;
		cluster.set_master_wait_ms(5000);
		uint64_t ver = cluster.get_node_map_version() + 10;
		vector<cluster::node> v;
		v.push_back(mk("localhost", 11211, cluster::role_master, cluster::state_down, 0));
		v.push_back(mk("s1", 12121, cluster::role_slave, cluster::state_active, 0));
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ver));
		const uint64_t waited0 = stats_object->get_reads_waited_for_master();
		ppr_arg a;
		a.c = &cluster;
		a.key = "k";
		a.result = -100;
		st(&a.done, 0);
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, run_ppr, &a));
		usleep(300 * 1000);
		const int done_early = ld(&a.done);
		v[0] = mk("localhost", 11211, cluster::role_master, cluster::state_active, 0);
		const int rc = cluster.reconstruct_node(v, ++ver);
		const bool finished = wait_flag(&a.done, 5000);
		if (!finished) {
			cluster.set_master_wait_ms(0);
		}
		pthread_join(t, NULL);
		cut_assert_equal_int(0, done_early, cut_message("the read did not wait for a master"));
		cppcut_assert_equal(0, rc);
		cut_assert_true(finished);
		cut_assert_equal_int(cluster::proxy_request_continue, a.result);
		cut_assert(a.ms >= 250, cut_message("answered after %ld ms", a.ms));
		cut_assert_equal_int(1, (int)(stats_object->get_reads_waited_for_master() - waited0));
	}

	// ... and fails with the partition error when no master comes within the
	// wait; with W off (0) at once, as before
	void test_a_read_waiting_for_a_master_fails_at_the_bound()
	{
		const std::string _tmp_dir = tmp_dir + std::string("/read_master_wait_bound");
		mkdir(_tmp_dir.c_str(), 0700);
		cluster_test cluster(_tmp_dir);
		cluster._type = cluster::type_node;
		cluster.set_master_wait_ms(400);
		uint64_t ver = cluster.get_node_map_version() + 10;
		vector<cluster::node> v;
		v.push_back(mk("localhost", 11211, cluster::role_master, cluster::state_down, 0));
		v.push_back(mk("s1", 12121, cluster::role_slave, cluster::state_active, 0));
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ver));
		ppr_arg a;
		a.c = &cluster;
		a.key = "k";
		st(&a.done, 0);
		run_ppr(&a);
		cut_assert_equal_int(cluster::proxy_request_error_partition, a.result);
		cut_assert(a.ms >= 350 && a.ms < 2000, cut_message("failed after %ld ms (bound 400)", a.ms));
		cluster.set_master_wait_ms(0);
		run_ppr(&a);
		cut_assert_equal_int(cluster::proxy_request_error_partition, a.result);
		cut_assert(a.ms < 200, cut_message("W off still waited %ld ms", a.ms));
	}

	// L4: a proxied change is applied as a replica only when its sender is a
	// master of the partition in this node's map — the current master, or
	// the master/down placeholder of a handover still draining its forwards.
	// From any other node (a late forward of an old map) it is routed like a
	// client write instead, never applied here as a replica. (The routed
	// case is checked with the partition's master down and no wait, so it
	// ends at once in the partition error: this cluster has no forwarding
	// threads.)
	void test_a_replica_applies_only_changes_from_a_master_of_the_partition()
	{
		const std::string _tmp_dir = tmp_dir + std::string("/replica_sender");
		mkdir(_tmp_dir.c_str(), 0700);
		cluster_test cluster(_tmp_dir);
		cluster._type = cluster::type_node;
		cluster.set_master_wait_ms(0);
		uint64_t ver = cluster.get_node_map_version() + 10;
		vector<cluster::node> v;
		v.push_back(mk("m1", 12121, cluster::role_master, cluster::state_active, 0));
		v.push_back(mk("localhost", 11211, cluster::role_slave, cluster::state_active, 0));
		v.push_back(mk("px", 12121, cluster::role_proxy, cluster::state_active, -1));
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ver));
		ppw_arg a;
		a.c = &cluster;
		a.key = "k";
		a.sender = "m1:12121";		// the current master
		run_ppw(&a);
		cut_assert_equal_int(cluster::proxy_request_continue, a.result);
		// a handover's demote step: m1 is the master/down placeholder
		v[0] = mk("m1", 12121, cluster::role_master, cluster::state_down, 0);
		cppcut_assert_equal(0, cluster.reconstruct_node(v, ++ver));
		a.sender = "m1:12121";		// its forwards still drain: applied
		run_ppw(&a);
		cut_assert_equal_int(cluster::proxy_request_continue, a.result);
		a.sender = "px:12121";		// a node of this cluster that is not a master
		run_ppw(&a);
		cut_assert_equal_int(cluster::proxy_request_error_partition, a.result,
			cut_message("a change from a non-master was applied as a replica (or not routed as a client write)"));
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
