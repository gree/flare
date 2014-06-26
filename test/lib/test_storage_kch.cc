/**
 *  test_storage_tch.cc
 *
 *  @author Daniel Perez <tuvistavie@hotmail.com>
 */
#include <cppcutter.h>

#include "common_storage_tests.h"
#include "storage_listener_simple.h"
#include <app.h>
#include <storage_engine_kch.h>

#include <limits>
#include <sys/stat.h>
#include <sys/types.h>

using namespace std;

namespace test_storage_kch
{
	const char tmp_dir[] = "/tmp/flare-cutter";
	storage_listener_simple listener;
	test_storage::storage_tester* kch_tester;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		const char *db_dir;
		db_dir = tmp_dir;
		cut_remove_path(db_dir, NULL);
		mkdir(db_dir, 0700);
		string compress("");
		storage_engine_kch* engine = new storage_engine_kch(
			db_dir,
			4, // ap
			131071, // bucket size
			compress,
			true, // large
			0, // dfunit
			&listener
		);
		kch_tester = new test_storage::storage_tester(new storage(
			32, // mutex slot
			65536, // cache size
			engine,
			&listener
		));
	}

COMMON_STORAGE_TEST(kch_tester, get_not_found);
COMMON_STORAGE_TEST(kch_tester, set_basic);
COMMON_STORAGE_TEST(kch_tester, set_empty_key);
COMMON_STORAGE_TEST(kch_tester, set_space_key);
COMMON_STORAGE_TEST(kch_tester, set_multiline_key);
COMMON_STORAGE_TEST(kch_tester, set_key_too_long_for_memcached);
COMMON_STORAGE_TEST(kch_tester, set_enormous_value);
COMMON_STORAGE_TEST(kch_tester, remove_not_found);
COMMON_STORAGE_TEST(kch_tester, remove_basic);
COMMON_STORAGE_TEST(kch_tester, multiple_iter_begin);
COMMON_STORAGE_TEST(kch_tester, iter_basic);
COMMON_STORAGE_TEST(kch_tester, iter_non_initialized);
COMMON_STORAGE_TEST(kch_tester, iter_end_error);
COMMON_STORAGE_TEST(kch_tester, iter_next_concurrent_add);
COMMON_STORAGE_TEST(kch_tester, iter_next_concurrent_replace);
COMMON_STORAGE_TEST(kch_tester, iter_next_concurrent_remove);
COMMON_STORAGE_TEST(kch_tester, truncate);
COMMON_STORAGE_TEST(kch_tester, count);
GENERATE_SET_TESTS(kch_tester);
GENERATE_INCR_TESTS(kch_tester);
GENERATE_REMOVE_TESTS(kch_tester);
GENERATE_GET_TESTS(kch_tester);

	void teardown()
	{
		delete kch_tester;
		cut_remove_path(tmp_dir, NULL);
		delete stats_object;
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
