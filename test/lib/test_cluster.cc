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

	struct swap_arg {
		cluster_test* c;
		uint64_t ver;
		volatile int done;
	};

	static void* swap_map(void* a) {
		swap_arg* x = static_cast<swap_arg*>(a);
		vector<cluster::node> v;
		x->c->reconstruct_node(v, x->ver);
		x->done = 1;
		return NULL;
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
		a.done = 0;
		cluster.write_section_enter();
		cluster.write_section_enter();		// nested: depth 2, one lock
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, swap_map, &a));
		usleep(300 * 1000);
		cut_assert_equal_int(0, a.done, cut_message("the map was swapped while a write was in its section"));
		cluster.write_section_leave();		// depth 1: still held
		usleep(300 * 1000);
		cut_assert_equal_int(0, a.done, cut_message("the map was swapped after the inner leave"));
		cluster.write_section_leave();		// released
		for (int i = 0; i < 50 && !a.done; i++) {
			usleep(100 * 1000);
		}
		pthread_join(t, NULL);
		cut_assert_equal_int(1, a.done);
		cppcut_assert_equal(a.ver, cluster.get_node_map_version());
		// an unbalanced leave is ignored
		cluster.write_section_leave();
		cluster.write_section_enter();
		cluster.write_section_leave();
	}

	struct reader_arg {
		cluster_test* c;
		volatile int stop;
		volatile long entries;
	};

	static void* steady_writer(void* a) {
		reader_arg* x = static_cast<reader_arg*>(a);
		while (!x->stop) {
			x->c->write_section_enter();
			usleep(300);
			x->c->write_section_leave();
			x->entries++;
		}
		return NULL;
	}

	// NODE-OPS-LOSSLESS-PLAN L1, review of 8d64aaf: under a steady write load
	// (overlapping readers that never all leave at once) a map swap still gets
	// the section within a bound — the lock prefers the writer (glibc)
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
			ra[i].stop = 0;
			ra[i].entries = 0;
			cut_assert_equal_int(0, pthread_create(&rt[i], NULL, steady_writer, &ra[i]));
		}
		usleep(200 * 1000);
		swap_arg a;
		a.c = &cluster;
		a.ver = cluster.get_node_map_version() + 10;
		a.done = 0;
		struct timespec t0, t1;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, swap_map, &a));
		for (int i = 0; i < 200 && !a.done; i++) {
			usleep(10 * 1000);
		}
		clock_gettime(CLOCK_MONOTONIC, &t1);
		const long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
		long before = 0;
		for (int i = 0; i < n; i++) {
			before += ra[i].entries;
		}
		for (int i = 0; i < n; i++) {
			ra[i].stop = 1;
		}
		for (int i = 0; i < n; i++) {
			pthread_join(rt[i], NULL);
		}
		pthread_join(t, NULL);
		cut_assert_equal_int(1, a.done, cut_message("the map swap did not get the write section within 2 s under a steady write load (%ld ms, %ld writes)", ms, before));
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
		a.done = 0;
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, swap_map, &a));
		usleep(300 * 1000);
		cut_assert_equal_int(0, a.done, cut_message("c2's map was swapped while a write was in c2's section"));
		c2.write_section_leave();
		for (int i = 0; i < 50 && !a.done; i++) {
			usleep(100 * 1000);
		}
		pthread_join(t, NULL);
		cut_assert_equal_int(1, a.done);
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
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
