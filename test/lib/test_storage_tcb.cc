/**
 *	test_storage_tcb.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */
#include <cppcutter.h>

#include "common_storage_tests.h"
#include "storage_listener_simple.h"
#include <app.h>
#include <storage_engine_tcb.h>

#include <limits>
#include <sys/stat.h>
#include <sys/types.h>

using namespace std;

namespace test_storage_tcb
{
	const char tmp_dir[] = "/tmp/flare-cutter";
	storage_listener_simple listener;
	test_storage::storage_tester* tcb_tester;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		const char *db_dir;
		db_dir = tmp_dir;
		cut_remove_path(db_dir, NULL);
		mkdir(db_dir, 0700);
		string compress("");
		storage_engine_tcb* engine = new storage_engine_tcb(
			db_dir,
			4, // ap
			10, // fp
			131071, // bucket size
			compress,
			true, // large
			0, // lmemb
			0, // nmemb
			0, // dfunit
			&listener
		);
		tcb_tester = new test_storage::storage_tester(new storage(
			32, // mutex slot
			65536, // cache size
			engine,
			&listener
		));
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
