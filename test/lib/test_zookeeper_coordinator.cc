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
 *	test-zookeeper-coordinator.cc
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 */

#include <sys/stat.h>
#include <sys/types.h>

#include "app.h"
#include "stats.h"
#include "coordinator_factory.h"
#include "zookeeper_coordinator.h"

#include <cppcutter.h>
#include <boost/thread.hpp>
#include <boost/format.hpp>
#include <boost/bind.hpp>

#include <stdlib.h>

using namespace std;
using namespace gree::flare;

namespace test_zookeeper_coordinator {
	AtomicCounter thread_idx(1);
	thread_pool req_tp(10, 8192, &thread_idx);
	thread_pool other_tp(10, 8192, &thread_idx);
	char* connstring = NULL;
	char* connuri = NULL;
	zhandle_t* zhandle;
	const char* meta[][2] = {
		{ "partition-size", "1024" },
		{ "key-hash-algorithm", "crc32" },
		{ "partition-type", "modular" },
		{ "partition-modular-hint", "1" },
		{ "partition-modular-virtual", "65536" },
		{ NULL, NULL },
	};

	void setup() {
		connstring = getenv("TEST_ZOOKEEPER_COORDINATOR_COORD");
		if (connstring) {
			connuri = strdup((string("zookeeper://")+connstring).c_str());
			zoo_set_debug_level(ZOO_LOG_LEVEL_ERROR);
			singleton<logger>::instance().open("test_zkcoord", "local0", false);
		}

		stats_object = new stats();
		stats_object->startup();

		if (connstring) {
			zhandle = zookeeper_init(connstring, NULL, 10000, 0, NULL, 0);
			int ret = zoo_create(zhandle, "/index", "", 0, &ZOO_OPEN_ACL_UNSAFE, 0, NULL, 0);
			zoo_create(zhandle, "/index/servers", "", 0, &ZOO_OPEN_ACL_UNSAFE, 0, NULL, 0);
			zoo_create(zhandle, "/index/lock", "", 0, &ZOO_OPEN_ACL_UNSAFE, 0, NULL, 0);
			char initialFlareXml[] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>\n"
				"<!DOCTYPE boost_serialization>\n"
				"<boost_serialization signature=\"serialization::archive\" version=\"4\">\n"
				"<version>0</version>\n"
				"<node_map class_id=\"0\" tracking_level=\"0\" version=\"0\">\n"
				"\t<count>0</count>\n"
				"\t<item_version>0</item_version>\n"
				"</node_map>\n"
				"<thread_type>16</thread_type>\n"
				"</boost_serialization>\n";
			zoo_create(zhandle, "/index/nodemap", initialFlareXml, strlen(initialFlareXml), &ZOO_OPEN_ACL_UNSAFE, 0, NULL, 0);
			zoo_create(zhandle, "/index/meta", "", 0, &ZOO_OPEN_ACL_UNSAFE, 0, NULL, 0);
			for (int i = 0; meta[i][0]; i++) {
				char buf[256];
				strcpy(buf, meta[i][1]);
				zoo_create(zhandle, (string("/index/meta/") + meta[i][0]).c_str(), "", 0, &ZOO_OPEN_ACL_UNSAFE, 0, buf, strlen(buf));
			}
		}
	}

	void teardown() {
		if (connstring) {
			zoo_delete(zhandle, "/index/lock", -1);
			zoo_delete(zhandle, "/index/servers", -1);
			zoo_delete(zhandle, "/index/nodemap", -1);
			for (int i = 0; meta[i][0]; i++) {
				char buf[256];
				strcpy(buf, meta[i][1]);
				zoo_delete(zhandle, (string("/index/meta/") + meta[i][0]).c_str(), -1);
			}
			zoo_delete(zhandle, "/index/meta", -1);
			zoo_delete(zhandle, "/index", -1);
			zookeeper_close(zhandle);
			free(connuri);
			singleton<logger>::instance().close();
		}
		delete stats_object;
	}

	void check(zookeeper_coordinator& fc, const string& scheme = "", const string& authority = "",
						 const string& user = "", const string& host = "", const int port = 0,
						 const string& path = "/") {
#if 0
		cout << "scheme=\"" << fc.get_scheme() << "\", "
				 << "host=\"" << fc.get_host() << "\", "
				 << "port=\"" << fc.get_port() << "\", "
				 << "path=\"" << fc.get_path() << "\""
				 << endl;
#endif
		cut_assert_equal_string(scheme.c_str(), fc.get_scheme().c_str());
		if (host != "") cut_assert_equal_string(host.c_str(), fc.get_host().c_str());
		if (port != 0) cppcut_assert_equal(port, fc.get_port());
		if (path != "/") cut_assert_equal_string(path.c_str(), fc.get_path().c_str());
	}

	void test_scheme() {
		if (!connuri) return;
		
		zookeeper_coordinator zc_dot("zookeeper://./", "localhost:12120");
		check(zc_dot, "zookeeper", "", "", ".", 0, "/");
		zookeeper_coordinator zc_local("zookeeper://./var/run/flare/flare.xml", "localhost:12120");
		check(zc_local, "zookeeper", "", "", ".", 0, "/var/run/flare/flare.xml");
		zookeeper_coordinator zc_emptyhost("zookeeper:///var/run/flare/flare.xml", "localhost:12120");
		check(zc_emptyhost, "zookeeper", "", "", "", 0, "/var/run/flare/flare.xml");
		zookeeper_coordinator zc_full("zookeeper://hostname.domain.net:2181/flare/index", "localhost:12120");
		check(zc_full, "zookeeper", "", "", "hostname.domain.net", 2181, "/flare/index");
		zookeeper_coordinator zc_multi("zookeeper://hostname.domain.net:2181,hostname2.domain.net:2182/flare/index", "localhost:12120");
		vector<zookeeper_coordinator::authority_type> authorities = zc_multi.get_authorities();
		for (vector<zookeeper_coordinator::authority_type>::iterator it = authorities.begin();
				 it != authorities.end(); it++) {
			cout << it->get<0>() << "," << it->get<1>() << "," << it->get<2>() << endl;
		}
		check(zc_multi, "zookeeper", "", "", "hostname.domain.net", 2181, "/flare/index");
	}

	void test_real() {
		if (!connuri) return;

		zookeeper_coordinator zc_real(connuri, "localhost:12120");
		check(zc_real, "zookeeper", "", "");
	}

	void test_lock() {
		if (!connuri) return;

		zookeeper_coordinator zc(connuri, "localhost:12120");
		coordinator::shared_operation operation;
		cout << "begin lock: " << zc.begin_operation(operation, "message") << endl;
		cout << "end lock: " << zc.end_operation(operation) << endl;
	}

	void random_nanosleep(int limit_nsec = 1000000) {
		struct timespec	ts;
		ts.tv_sec = 0;
		ts.tv_nsec = rand() % limit_nsec;
		nanosleep(&ts, 0);
	}

	void many_locker_main(CutTestContext* context, int i) {
		cut_set_current_test_context(context);
		if (!connuri) return;

		zookeeper_coordinator zc(connuri, (boost::format("localhost:%1%") % i).str());
		random_nanosleep(100);
		coordinator::shared_operation operation;
		if (zc.begin_operation(operation, (boost::format("many_locker_main %1%") % i).str()) == 0) {
			random_nanosleep(1000);
			zc.end_operation(operation);
		}
	}

	void test_many_locker1() {
		if (!connuri) return;

		boost::thread_group tg;
		for (int i = 0; i < 10; i++) {
			tg.create_thread(boost::bind(&many_locker_main, cut_get_current_test_context(), i));
		}
		tg.join_all();
	}

	void test_many_locker2() {
		if (!connuri) return;

		boost::thread_group tg;
		for (int i = 0; i < 50; i++) {
			tg.create_thread(boost::bind(&many_locker_main, cut_get_current_test_context(), i));
		}
		tg.join_all();
	}

	void test_restore() {
		if (!connuri) return;
		
		string data;
		zookeeper_coordinator zc(connuri, "localhost:12120");
		cut_assert_equal_int(0, zc.restore_state(data));
	}

	void store_and_restore(CutTestContext* context, int i) {
		cut_set_current_test_context(context);
		if (!connuri) return;

		zookeeper_coordinator* zc;
		string input;
		string output;

		zc = new zookeeper_coordinator(connuri, "localhost:12120");
		random_nanosleep(100);
		for (int i = 0; i < 10; i++) {
			coordinator::shared_operation operation;
			if (zc->begin_operation(operation, (boost::format("store_and_restore %1%") % i).str()) == 0) {
				random_nanosleep(1000);
				cut_assert_equal_int(0, zc->restore_state(input));
				cut_assert_equal_int(0, zc->store_state(input));
				cut_assert_equal_int(0, zc->restore_state(output));
				zc->end_operation(operation);
			}
		}
		delete zc;
		
		if (input != output) {
			cout << input << " <-> " << output << endl;
		}
	}

	void test_store_and_restore() {
		if (!connuri) return;

		boost::thread_group tg;
		for (int i = 0; i < 50; i++) {
			tg.create_thread(boost::bind(&store_and_restore, cut_get_current_test_context(), i));
		}
		tg.join_all();
	}

	void test_cluster_simple() {
		if (!connuri) return;

		coordinator_factory cf;
		coordinator* coord = cf.create_coordinator(connuri, "localhost:12120");
		cluster* cl = new cluster(&req_tp, &other_tp, "localhost", 12120);

		key_resolver::type t;
		key_resolver::type_cast("modular", t);
		cppcut_assert_equal(0, cl->startup_index(coord, t, 1, 4096));

		vector<cluster::node> nodes = cl->get_node();
		for (vector<cluster::node>::iterator it = nodes.begin(); it != nodes.end(); it++) {
			string s = (boost::format("%1% %2% %3% %4% %5% %6% %7%") % it->node_server_name % it->node_server_port
									% it->node_role % it->node_state % it->node_partition % it->node_balance
									% it->node_thread_type).str();
			cout << s << endl;
		}

		delete cl;
		cf.destroy_coordinator(coord);
	}

	void test_zookeeper_connection_string_parse1() {
		static const char * pattern = ",?([^,:]+):(\\d+)";
		string index_servers = "hoge.com:1234,piyo.org:4567,huga.net:2468";
		vector<string> authstrings;
		static const boost::regex e(pattern);
		boost::smatch match;
		string::const_iterator start = index_servers.begin();
		string::const_iterator end = index_servers.end();

		vector<string> v;
		while (boost::regex_search(start, end, match, e)) {
			v.push_back(match.str(1)+":"+match.str(2));
			start = match[0].second;
		}
		
		cut_assert_equal_string("hoge.com:1234", v[0].c_str());
		cut_assert_equal_string("piyo.org:4567", v[1].c_str());
		cut_assert_equal_string("huga.net:2468", v[2].c_str());
	}
}
