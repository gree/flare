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
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#include <app.h>
#include <cluster.h>
#include <coordinator_factory.h>
#include <stats.h>
#include <write_fence.h>
#include <write_promise.h>

#include "mock_storage.h"

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

		// keep the no-op handler when the previous action was the default (terminate): a thread still
		// finishing its shutdown can get its SIGUSR1 after this teardown (exit 138, 'User defined signal 1')
		if (prev_sigusr1_action.sa_handler != SIG_DFL && sigaction(SIGUSR1, &prev_sigusr1_action, NULL) < 0) {
			log_err("sigaction for %d failed: %s (%d)", SIGUSR1, util::strerror(errno), errno);
			return;
		}
	}

	struct cluster_test : public cluster
	{
		void lock_node_map() { pthread_rwlock_wrlock(&this->_mutex_node_map); }
		void unlock_node_map() { pthread_rwlock_unlock(&this->_mutex_node_map); }
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
	// C' write authority: the boot map names this node master before any authority message arrives.
	// The gate refuses (an existing copy needs the committed intent) and the node stays a non-serving
	// candidate; the refused shift is re-evaluated when the missing condition arrives, without a new
	// map and without a restart. Nothing else lifts it.
	static uint64_t fake_ns = 0;
	static uint64_t fake_clock() { return fake_ns; }
	static const uint64_t S = 1000000000ULL;
	static std::string probe_boot = "b1", probe_copy = "c1";
	static void probe(std::string& b, std::string& c) { b = probe_boot; c = probe_copy; }

	struct authority_fixture {
		authority_fixture(const char* dir):
				cl(std::string(dir)), st(std::string(tmp_dir) + "/" + dir + "-st", 16, 16) {
			write_fence::reset_for_test();
			write_promise::reset_for_test();
			fake_ns = 1000 * S;
			probe_boot = "b1";
			probe_copy = "c1";
			write_fence::authority_set_clock(fake_clock);
			std::string why;
			cut_assert_true(write_promise::configure(true, 2000, 10000, why));
			write_promise::set_identity_probe(probe);
		}
		~authority_fixture() {
			cl.set_storage(NULL);
			write_fence::reset_for_test();
			write_promise::reset_for_test();
		}
		// the boot map: this node (localhost:11211) is the master of partition 0, active
		void boot_as_master() {
			cl._type = cluster::type_node;
			vector<cluster::node> v;
			v.push_back(mk("localhost", 11211, cluster::role_master, cluster::state_active, 0));
			cppcut_assert_equal(0, cl.reconstruct_node(v, cl.get_node_map_version() + 10));
			cl.set_storage(&st);
			cppcut_assert_equal(0, cl.run_boot_shift());
		}
		cluster_test cl;
		mock_storage st;
	};

	void test_promotion_refused_by_the_gate_completes_when_the_first_build_is_allowed()
	{
		mkdir((tmp_dir + "/wa1").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa1").c_str());
		// startup order: the boot map arrives while the storage is not attached yet (the shift is only
		// deferred, nothing is recorded), then storage + run_boot_shift record the refusal, and only
		// that recorded refusal is re-evaluated
		f.cl._type = cluster::type_node;
		vector<cluster::node> v;
		v.push_back(mk("localhost", 11211, cluster::role_master, cluster::state_active, 0));
		cppcut_assert_equal(0, f.cl.reconstruct_node(v, f.cl.get_node_map_version() + 10));
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());		// no storage yet: must not touch it
		cppcut_assert_equal(std::string("none"), f.cl.get_promotion_retry_reason());
		f.cl.set_storage(&f.st);
		cppcut_assert_equal(0, f.cl.run_boot_shift());
		cppcut_assert_equal(std::string("authority"), f.cl.get_promotion_retry_reason());
		cut_assert_true(f.cl.is_promotion_refused());		// no proof, no intent: a non-serving candidate
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());		// nothing changed: still refused
		std::string why;
		cut_assert_false(write_promise::allow_first_build(0, "b1", "c-other", why));		// a proof of another copy
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());
		cut_assert_true(write_promise::allow_first_build(0, "b1", "c1", why));
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_false(f.cl.is_promotion_refused());		// completed, no new map, no restart
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_false(f.cl.is_promotion_refused());		// and not refused again
	}

	static void* hold_node_map_lock(void* arg)
	{
		cluster_test* cl = static_cast<cluster_test*>(arg);
		cl->lock_node_map();
		usleep(1500 * 1000);		// a long reconstruct
		cl->unlock_node_map();
		return NULL;
	}

	// the first-build hook must not wait behind a long reconstruct: with the node map lock held
	// elsewhere the bounded retry returns within its bound without evaluating anything (the gate is not
	// touched, the refusal stays), and the periodic retry runs it once the lock is free
	void test_the_bounded_retry_gives_up_while_the_locks_are_held_and_the_periodic_retry_runs_it_later()
	{
		mkdir((tmp_dir + "/wa1b").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa1b").c_str());
		f.cl._type = cluster::type_node;
		vector<cluster::node> v;
		v.push_back(mk("localhost", 11211, cluster::role_master, cluster::state_active, 0));
		cppcut_assert_equal(0, f.cl.reconstruct_node(v, f.cl.get_node_map_version() + 10));
		f.cl.set_storage(&f.st);
		cppcut_assert_equal(0, f.cl.run_boot_shift());
		cut_assert_true(f.cl.is_promotion_refused());
		std::string why;
		cut_assert_true(write_promise::allow_first_build(0, "b1", "c1", why));

		pthread_t th;
		cppcut_assert_equal(0, pthread_create(&th, NULL, hold_node_map_lock, &f.cl));
		usleep(200 * 1000);		// the holder has the lock
		struct timespec t0, t1;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		bool skipped = false;
		cppcut_assert_equal(0, f.cl.retry_refused_promotion_bounded(100, &skipped));
		clock_gettime(CLOCK_MONOTONIC, &t1);
		const long ms = (t1.tv_sec - t0.tv_sec) * 1000L + (t1.tv_nsec - t0.tv_nsec) / 1000000L;
		cut_assert_true(skipped);
		cut_assert_true(ms >= 90 && ms < 1000);		// returned at its bound, not when the holder let go
		cut_assert_true(f.cl.is_promotion_refused());		// nothing evaluated

		pthread_join(th, NULL);
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());		// the periodic retry: same gate, now free
		cut_assert_false(f.cl.is_promotion_refused());

		// free locks: the bounded call evaluates (not skipped) and is a no-op with nothing pending
		skipped = true;
		cppcut_assert_equal(0, f.cl.retry_refused_promotion_bounded(100, &skipped));
		cut_assert_false(skipped);
	}

	void test_promotion_refused_by_the_gate_completes_when_the_committed_intent_is_promotable()
	{
		mkdir((tmp_dir + "/wa2").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa2").c_str());
		f.boot_as_master();
		cut_assert_true(f.cl.is_promotion_refused());
		write_promise::scope sc;
		sc.intent = 1;
		sc.term_next = 2;
		sc.generation = 1;
		write_promise::identity(sc.boot, sc.copy);
		write_promise::status s;
		std::string why;
		write_fence::authority_set_floor(0, 1, 1);
		cut_assert_true(write_promise::prepare(0, sc, s, why));
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());		// prepared, not committed
		cut_assert_true(write_promise::commit(0, sc, s, why));
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());		// committed, but the quiet time has not passed
		fake_ns += 100 * S;
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_false(f.cl.is_promotion_refused());
	}

	void test_a_map_that_takes_the_master_role_away_drops_the_retry()
	{
		mkdir((tmp_dir + "/wa3").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa3").c_str());
		f.boot_as_master();
		cut_assert_true(f.cl.is_promotion_refused());
		vector<cluster::node> v;
		v.push_back(mk("localhost", 11211, cluster::role_proxy, cluster::state_active, -1));
		cppcut_assert_equal(0, f.cl.reconstruct_node(v, f.cl.get_node_map_version() + 10));
		cut_assert_false(f.cl.is_promotion_refused());
		std::string why;
		cut_assert_true(write_promise::allow_first_build(0, "b1", "c1", why));
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());		// nothing pending: the proof does not make it master
		cut_assert_false(f.cl.is_promotion_refused());
	}
	// a copy that is forbidden as a master is a refusal of its own reason: when it clears, the whole
	// shift runs again (authority gate included) without a new map — and the first-build allowance is
	// not burnt by the shifts the copy refused before
	void test_forbidden_copy_refusal_is_re_evaluated_when_the_copy_is_fit_again()
	{
		mkdir((tmp_dir + "/wa4").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa4").c_str());
		f.st.forbidden = true;
		f.st.forbidden_why = "copy not fit";
		std::string why;
		cut_assert_true(write_promise::allow_first_build(0, "b1", "c1", why));
		f.boot_as_master();
		cut_assert_true(f.cl.is_promotion_refused());
		cppcut_assert_equal(std::string("copy not fit"), f.cl.get_promotion_refused_why());
		cppcut_assert_equal(std::string("copy"), f.cl.get_promotion_retry_reason());
		for (int i = 0; i < 3; i++) {
			cppcut_assert_equal(0, f.cl.retry_refused_promotion());
			cut_assert_true(f.cl.is_promotion_refused());
		}
		f.st.forbidden = false;		// nothing else changes: no map, no restart
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_false(f.cl.is_promotion_refused());		// the allowance survived the refused shifts
		cppcut_assert_equal(std::string("none"), f.cl.get_promotion_retry_reason());
	}

	void test_forbidden_copy_that_clears_still_meets_the_authority_gate()
	{
		mkdir((tmp_dir + "/wa5").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa5").c_str());
		f.st.forbidden = true;
		f.st.forbidden_why = "copy not fit";
		f.boot_as_master();
		cut_assert_true(f.cl.is_promotion_refused());
		f.st.forbidden = false;
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());		// the copy is fit; no proof, no intent: the gate still refuses
		cut_assert_true(f.cl.get_promotion_refused_why().find("write authority") == 0);
		cppcut_assert_equal(std::string("authority"), f.cl.get_promotion_retry_reason());		// the reason moved from copy to authority
		std::string why;
		cut_assert_true(write_promise::allow_first_build(0, "b1", "c1", why));
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_false(f.cl.is_promotion_refused());
	}

	// control: an existing copy (no first-build proof, no committed intent) stays refused across any
	// number of retries and across a forbidden copy that clears
	void test_existing_copy_proxy_to_master_stays_refused_across_retries()
	{
		mkdir((tmp_dir + "/wa6").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa6").c_str());
		f.boot_as_master();
		for (int i = 0; i < 20; i++) {
			fake_ns += 10 * S;
			cppcut_assert_equal(0, f.cl.retry_refused_promotion());
			cut_assert_true(f.cl.is_promotion_refused());
		}
		f.st.forbidden = true;
		f.st.forbidden_why = "x";
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		f.st.forbidden = false;
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());
		cut_assert_true(f.cl.get_promotion_refused_why().find("no first-build proof") != std::string::npos);
	}

	// the allowance is bound to the exact incarnation and copy, and is used once
	void test_first_build_allowance_is_not_reusable_after_a_restart()
	{
		mkdir((tmp_dir + "/wa7").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa7").c_str());
		f.boot_as_master();
		std::string why;
		cut_assert_true(write_promise::allow_first_build(0, "b1", "c1", why));
		probe_boot = "b2";		// the node restarted: a new boot id
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());
		probe_boot = "b1";		// even the old identity does not bring it back: it was voided
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());
	}

	void test_first_build_allowance_is_not_reusable_after_a_copy_change()
	{
		mkdir((tmp_dir + "/wa8").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa8").c_str());
		f.boot_as_master();
		std::string why;
		cut_assert_true(write_promise::allow_first_build(0, "b1", "c1", why));
		probe_copy = "c2";		// the data directory was replaced: a new copy id
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());
		probe_copy = "c1";
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_true(f.cl.is_promotion_refused());
	}

	void test_first_build_allowance_is_consumed_by_the_promotion_it_allowed()
	{
		mkdir((tmp_dir + "/wa9").c_str(), 0700);
		authority_fixture f((tmp_dir + "/wa9").c_str());
		f.boot_as_master();
		std::string why;
		cut_assert_true(write_promise::allow_first_build(0, "b1", "c1", why));
		cppcut_assert_equal(0, f.cl.retry_refused_promotion());
		cut_assert_false(f.cl.is_promotion_refused());
		vector<cluster::node> v;		// demoted, then named master again by a later map
		v.push_back(mk("localhost", 11211, cluster::role_proxy, cluster::state_active, -1));
		cppcut_assert_equal(0, f.cl.reconstruct_node(v, f.cl.get_node_map_version() + 10));
		v[0] = mk("localhost", 11211, cluster::role_master, cluster::state_active, 0);
		cppcut_assert_equal(0, f.cl.reconstruct_node(v, f.cl.get_node_map_version() + 10));
		cut_assert_true(f.cl.is_promotion_refused());		// the old allowance is gone
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
