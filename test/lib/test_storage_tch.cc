/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * Copyright (C) Kouhei Sutou <kou@clear-code.com>
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
 *	test_storage_tch.cc
 *
 *	@author	Kouhei Sutou <kou@clear-code.com>
 */
#include <cppcutter.h>

#include "common_storage_tests.h"
#include <app.h>
#include <storage_tch.h>

#include <limits>
#include <sys/stat.h>
#include <sys/types.h>

using namespace std;

namespace test_storage_tch
{
	const char tmp_dir[] = "tmp";
	storage_tch* tch = NULL;
	test_storage::storage_tester* tch_tester;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		const char *db_dir;
		db_dir = tmp_dir;
		mkdir(db_dir, 0700);
		string compress("");
		tch_tester = new test_storage::storage_tester(new storage_tch(db_dir,
					32,
					4,
					10,
					131071,
					65536,
					compress,
					true,
					0));
	}

COMMON_STORAGE_TEST(tch_tester, get_not_found);
COMMON_STORAGE_TEST(tch_tester, set_basic);
COMMON_STORAGE_TEST(tch_tester, set_empty_key);
COMMON_STORAGE_TEST(tch_tester, set_space_key);
COMMON_STORAGE_TEST(tch_tester, set_multiline_key);
COMMON_STORAGE_TEST(tch_tester, set_key_too_long_for_memcached);
COMMON_STORAGE_TEST(tch_tester, set_enormous_value);
COMMON_STORAGE_TEST(tch_tester, append_keep_flag);
COMMON_STORAGE_TEST(tch_tester, prepend_keep_flag);
COMMON_STORAGE_TEST(tch_tester, remove_not_found);
COMMON_STORAGE_TEST(tch_tester, remove_basic);
COMMON_STORAGE_TEST(tch_tester, multiple_iter_begin);
COMMON_STORAGE_TEST(tch_tester, iter_basic);
COMMON_STORAGE_TEST(tch_tester, iter_non_initialized);
COMMON_STORAGE_TEST(tch_tester, iter_end_error);
COMMON_STORAGE_TEST(tch_tester, iter_next_concurrent_add);
COMMON_STORAGE_TEST(tch_tester, iter_next_concurrent_replace);
COMMON_STORAGE_TEST(tch_tester, iter_next_concurrent_remove);
COMMON_STORAGE_TEST(tch_tester, truncate);
COMMON_STORAGE_TEST(tch_tester, count);
GENERATE_SET_TESTS(tch_tester);
GENERATE_INCR_TESTS(tch_tester);
GENERATE_REMOVE_TESTS(tch_tester);
GENERATE_GET_TESTS(tch_tester);

	void teardown()
	{
		delete tch_tester;
		cut_remove_path(tmp_dir, NULL);
		delete stats_object;
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
