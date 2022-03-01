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

//#include <sys/stat.h>
//#include <sys/types.h>

#include "logger.h"
#include "zookeeper_lock.h"

#include <cppcutter.h>
#include <boost/thread.hpp>
#include <boost/format.hpp>
#include <boost/bind.hpp>

#define ZHANDLE_SOCK(x) (*(reinterpret_cast<int*>(x)))

using namespace std;
using namespace gree::flare;

namespace test_zookeeper_lock {
	char* connstring = NULL;
	char* connuri = NULL;
	zhandle_t* zhandle;
	char work_path[] = "/lock";
	int nworkers = 500;

	void setup() {
		singleton<logger>::instance().open("test_zookeeper_lock", "local2", false);
		log_debug("----------------------------------------------------------------", 0);

		connstring = getenv("TEST_ZOOKEEPER_COORDINATOR_COORD");
		zoo_set_debug_level(ZOO_LOG_LEVEL_ERROR);

		if (connstring) {
			zhandle = zookeeper_init(connstring, NULL, 10000, 0, NULL, 0);
			zoo_delete(zhandle, work_path, -1);
			zoo_create(zhandle, work_path, "", 0, &ZOO_OPEN_ACL_UNSAFE, 0, NULL, 0);
		}
	}

	void teardown() {
		if (connstring) {
			zoo_delete(zhandle, work_path, -1);
			zookeeper_close(zhandle);
		}
		log_debug("----------------------------------------------------------------", 0);
		singleton<logger>::instance().close();
	}

	void random_nanosleep(int limit_nsec = 1000000) {
		struct timespec	ts;
		ts.tv_sec = 0;
		ts.tv_nsec = rand() % limit_nsec;
		nanosleep(&ts, 0);
	}

	void test_lock_and_unlock() {
		if (!zhandle) return;
		log_debug("-------------------------------- lock and unlock", 0);

		zookeeper_lock zl(connstring, work_path);
		cut_assert_equal_int(0, zl.lock());               // watch
		cut_assert_equal_int(0, zl.wait_for_ownership()); // wait
		cut_assert_equal_int(0, zl.unlock());	            // delete myself
	}

	void many_locker_main(CutTestContext* context, int i) {
		cut_set_current_test_context(context);

		random_nanosleep(100);
		zookeeper_lock zl(connstring, work_path);
		cut_assert_equal_int(0, zl.lock());
		cut_assert_equal_int(0, zl.wait_for_ownership());
		random_nanosleep(1000);
		cut_assert_equal_int(0, zl.unlock());		
	}

	void test_many_locker1() {
		if (!zhandle) return;
		log_debug("-------------------------------- many locker1", 0);
		boost::thread_group tg;
		for (int i = 0; i < 10; i++) {
			tg.create_thread(boost::bind(&many_locker_main, cut_get_current_test_context(), i));
		}
		tg.join_all();
	}

	void test_many_locker2() {
		if (!zhandle) return;
		log_debug("-------------------------------- many locker2", 0);
		boost::thread_group tg;
		for (int i = 0; i < 100; i++) {
			tg.create_thread(boost::bind(&many_locker_main, cut_get_current_test_context(), i));
		}
		tg.join_all();
	}

	void test_many_locker3() {
		if (!zhandle) return;
		log_debug("-------------------------------- many locker3", 0);
		boost::thread_group tg;
		for (int i = 0; i < nworkers; i++) {
			tg.create_thread(boost::bind(&many_locker_main, cut_get_current_test_context(), i));
		}
		tg.join_all();
	}
	
	void no_wait_main(CutTestContext* context, int i) {
		cut_set_current_test_context(context);

		random_nanosleep(100);
		zookeeper_lock zl(connstring, work_path);
		zl.set_message((boost::format("%1%") % i).str());
		cut_assert_equal_int(0, zl.lock());
		// cut_assert_equal_int(0, zl.wait_for_ownership()); // XXX
		random_nanosleep(1000);
		cut_assert_equal_int(0, zl.unlock());
	}

	void test_no_wait() {
		if (!zhandle) return;
		log_debug("-------------------------------- no wait", 0);
		boost::thread_group tg;
		for (int i = 0; i < 5; i++) {
			tg.create_thread(boost::bind(&no_wait_main, cut_get_current_test_context(), i));
		}
		tg.join_all();
	}

	void crush_locker_main(CutTestContext* context, int i) {
		cut_set_current_test_context(context);
		random_nanosleep(100);
		zookeeper_lock zl(connstring, work_path);
		zl.set_message((boost::format("%1%") % i).str());
		cut_assert_equal_int(0, zl.lock());
		cut_assert_equal_int(0, zl.wait_for_ownership());
		random_nanosleep(1000);
		cut_assert_equal_int(0, zl.unlock());		
	}

	void test_crush_locker_close() {
		if (!zhandle) return;
		log_debug("-------------------------------- crush locker close", 0);
		boost::thread_group tg;
		{
			zookeeper_lock zl(connstring, work_path);
			cut_assert_equal_int(0, zl.lock());
			cut_assert_equal_int(0, zl.wait_for_ownership());
			for (int i = 0; i < 100; i++) {
				tg.create_thread(boost::bind(&crush_locker_main, cut_get_current_test_context(), i));
			}
		}
		tg.join_all();
	}

	void test_crush_locker_shutdown() {
		if (!zhandle) return;
		log_debug("-------------------------------- crush locker shutdown", 0);
		boost::thread_group tg;
		{
			zookeeper_lock zl(connstring, work_path);
			cut_assert_equal_int(0, zl.lock());
			cut_assert_equal_int(0, zl.wait_for_ownership());
			for (int i = 0; i < nworkers; i++) {
				tg.create_thread(boost::bind(&crush_locker_main, cut_get_current_test_context(), i));
			}
			random_nanosleep(1000);
			::shutdown(ZHANDLE_SOCK(zl.get_zhandle()), SHUT_RD); // crush
		}
		tg.join_all();
	}

	void counting_main(CutTestContext* context, int i, volatile int* counter) {
		cut_set_current_test_context(context);
		random_nanosleep(100);
		zookeeper_lock zl(connstring, work_path);
		zl.set_message((boost::format("%1%") % i).str());
		cut_assert_equal_int(0, zl.lock());
		cut_assert_equal_int(0, zl.wait_for_ownership());
		int count = *counter;
		random_nanosleep(1000);
		*counter = count + 1;
		random_nanosleep(1000);
		cut_assert_equal_int(0, zl.unlock());
	}

	void test_counting() {
		if (!zhandle) return;
		log_debug("-------------------------------- counting", 0);
		volatile int counter = 0;
		boost::thread_group tg;
		for (int i = 0; i < nworkers; i++) {
			tg.create_thread(boost::bind(&counting_main, cut_get_current_test_context(), i, &counter));
		}
		tg.join_all();
		cut_assert_equal_int(nworkers, counter);
	}

	void cancelled_lock_main(CutTestContext* context, int i) {
		cut_set_current_test_context(context);
		random_nanosleep(100);
		zookeeper_lock *zl = new zookeeper_lock(connstring, work_path);
		zl->set_message((boost::format("%1%") % i).str());
		cut_assert_equal_int(0, zl->lock());
		random_nanosleep(1000);
		delete zl;
	}

	void normal_lock_main(CutTestContext* context, int i) {
		cut_set_current_test_context(context);
		random_nanosleep(100);
		zookeeper_lock *zl = new zookeeper_lock(connstring, work_path);
		zl->set_message((boost::format("%1%") % i).str());
		cut_assert_equal_int(0, zl->lock());
		random_nanosleep(100);
		cut_assert_equal_int(0, zl->wait_for_ownership());
		random_nanosleep(1000);
		cut_assert_equal_int(0, zl->unlock());
		delete zl;
	}

	void test_cancelled_lock() {
		if (!zhandle) return;
		log_debug("-------------------------------- cancelled lock", 0);
		boost::thread_group tg;
		for (int i = 0; i < 4; i++) {
			if (i % 2 == 0) {
				tg.create_thread(boost::bind(&normal_lock_main, cut_get_current_test_context(), i));
			} else {
				tg.create_thread(boost::bind(&cancelled_lock_main, cut_get_current_test_context(), i));
			}
		}
		tg.join_all();
	}
}
