/**
 *	test_storage_tcb.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */
#include <cppcutter.h>

#include "common_storage_tests.h"
#include <app.h>
#include <storage_tcb.h>

#include <limits>
#include <sys/stat.h>
#include <sys/types.h>

using namespace std;

namespace test_storage_tcb
{
	const char tmp_dir[] = "tmp";
	test_storage::storage_tester* tcb_tester;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		const char *db_dir;
		db_dir = tmp_dir;
		mkdir(db_dir, 0700);
		string compress("");
		tcb_tester = new test_storage::storage_tester(new storage_tcb(db_dir,
					32,
					4,
					131071,
					65536,
					compress,
					true,
					0,
					0,
					0));
	}

COMMON_STORAGE_TEST(tcb_tester, get_not_found);
COMMON_STORAGE_TEST(tcb_tester, set_basic);
COMMON_STORAGE_TEST(tcb_tester, set_empty_key);
COMMON_STORAGE_TEST(tcb_tester, set_space_key);
COMMON_STORAGE_TEST(tcb_tester, set_multiline_key);
COMMON_STORAGE_TEST(tcb_tester, set_key_too_long_for_memcached);
COMMON_STORAGE_TEST(tcb_tester, set_enormous_value);
COMMON_STORAGE_TEST(tcb_tester, append_keep_flag);
COMMON_STORAGE_TEST(tcb_tester, prepend_keep_flag);
COMMON_STORAGE_TEST(tcb_tester, remove_not_found);
COMMON_STORAGE_TEST(tcb_tester, remove_basic);
COMMON_STORAGE_TEST(tcb_tester, multiple_iter_begin);
COMMON_STORAGE_TEST(tcb_tester, iter_basic);
COMMON_STORAGE_TEST(tcb_tester, iter_non_initialized);
COMMON_STORAGE_TEST(tcb_tester, iter_end_error);
COMMON_STORAGE_TEST(tcb_tester, iter_next_concurrent_add);
COMMON_STORAGE_TEST(tcb_tester, iter_next_concurrent_replace);
COMMON_STORAGE_TEST(tcb_tester, iter_next_concurrent_remove);
COMMON_STORAGE_TEST(tcb_tester, truncate);
COMMON_STORAGE_TEST(tcb_tester, count);
GENERATE_SET_TESTS(tcb_tester);
GENERATE_INCR_TESTS(tcb_tester);
GENERATE_REMOVE_TESTS(tcb_tester);
GENERATE_GET_TESTS(tcb_tester);

	void teardown()
	{
		delete tcb_tester;
		cut_remove_path(tmp_dir, NULL);
		delete stats_object;
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
