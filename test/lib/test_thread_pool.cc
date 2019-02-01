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
 *	test_thread_pool.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include <app.h>
#include <thread_pool.h>

using namespace gree::flare;

namespace test_thread_pool
{
	void setup() {
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	struct thread_pool_test : public thread_pool
	{
		AtomicCounter thread_idx;
		thread_pool_test():
			thread_idx(1),
			thread_pool(128, 128, &thread_idx) { }
		~thread_pool_test() { }

		using thread_pool::_index;
		using thread_pool::_global_map;
		using thread_pool::_pool;
	};

	void test_duplicate_thread_id_different_types() {
		// Preparation
		thread_pool_test pool;
		cut_assert_equal_int(1, pool._index->fetch());
		//	Put a dummy thread (Type 0, ID 1, ensuring collision) in the global map
		shared_thread dummy(new gree::flare::thread(&pool));
		dummy->setup(0, pool._index->fetch());
		pool._global_map[0][dummy->get_id()] = dummy;
		// Test
		// 	Fetch thread, ID should be != 1
		shared_thread thread = pool.get(1);
		::sleep(1); // Avoids memory corruption when pool is destroyed too early
		cut_assert_not_equal_int(dummy->get_id(), thread->get_id());
	}

	void test_duplicate_thread_id_same_type() {
		// Preparation
		thread_pool_test pool;
		cut_assert_equal_int(1, pool._index->fetch());
		//	Put a dummy thread (Type 0, ID 1, ensuring collision) in the global map
		shared_thread dummy(new gree::flare::thread(&pool));
		dummy->setup(0, pool._index->fetch());
		pool._global_map[0][dummy->get_id()] = dummy;
		// Test
		// 	Fetch thread, ID should be != 1
		shared_thread thread = pool.get(0);
		::sleep(1); // Avoids memory corruption when pool is destroyed too early
		cut_assert_not_equal_int(dummy->get_id(), thread->get_id());
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
