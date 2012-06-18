/**
 *	test-storage-tc.cc
 *
 *	@author	Kouhei Sutou <kou@clear-code.com>
 */

#include <limits>

#include <sys/stat.h>
#include <sys/types.h>

#include <cppcutter.h>

#include <storage_tch.h>

#include "common-storage-tests.h"

using namespace std;

namespace test_storage_tch
{
	const char tmp_dir[] = "tmp";
	storage_tch* tch = NULL;

	void setup()
	{
		const char *db_dir;
		db_dir = tmp_dir;
		mkdir(db_dir, 0700);
		string compress("");
		tch = new storage_tch(db_dir,
					32,
					4,
					131071,
					65536,
					compress,
					true,
					0);
    tch->open();
	}

COMMON_STORAGE_TEST(tch, get_not_found);
COMMON_STORAGE_TEST(tch, set_basic);
COMMON_STORAGE_TEST(tch, set_empty_key);
COMMON_STORAGE_TEST(tch, set_space_key);
COMMON_STORAGE_TEST(tch, set_multiline_key);
COMMON_STORAGE_TEST(tch, set_key_too_long_for_memcached);
COMMON_STORAGE_TEST(tch, set_enormous_value);

	void teardown()
	{
    if (tch)
      delete tch;
		cut_remove_path(tmp_dir, NULL);
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
