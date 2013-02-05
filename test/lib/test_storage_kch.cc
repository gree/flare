/**
 *  test_storage_tch.cc
 *
 *  @author Daniel Perez <tuvistavie@hotmail.com>
 */
#include <cppcutter.h>

#include "common_storage_tests.h"
#include <app.h>
#include <storage_kch.h>

#include <limits>
#include <sys/stat.h>
#include <sys/types.h>

using namespace std;

namespace test_storage_kch
{
	const char tmp_dir[] = "tmp_kch";
	test_storage::storage_tester* kch_tester;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		const char *db_dir;
		db_dir = tmp_dir;
		mkdir(db_dir, 0700);
		string compress("");
		kch_tester = new test_storage::storage_tester(new storage_kch(db_dir,
					32,
					4,
					131071,
					65536,
					compress,
					true,
					0));
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
