/**
 *	test-storage-tcb.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <limits>

#include <sys/stat.h>
#include <sys/types.h>

#include <cppcutter.h>

#include <storage_tcb.h>

#include "common-storage-tests.h"

using namespace std;

namespace test_storage_tcb
{
	const char tmp_dir[] = "tmp";
	storage_tcb* tcb = NULL;

	void setup()
	{
		const char *db_dir;
		db_dir = tmp_dir;
		mkdir(db_dir, 0700);
		string compress("");
		tcb = new storage_tcb(db_dir,
					32,
					4,
					131071,
					65536,
					compress,
					true,
					0,
					0,
					0);
    tcb->open();
	}

COMMON_STORAGE_TEST(tcb, get_not_found);
COMMON_STORAGE_TEST(tcb, set_basic);
COMMON_STORAGE_TEST(tcb, set_empty_key);
COMMON_STORAGE_TEST(tcb, set_space_key);
COMMON_STORAGE_TEST(tcb, set_multiline_key);
COMMON_STORAGE_TEST(tcb, set_key_too_long_for_memcached);
COMMON_STORAGE_TEST(tcb, set_enormous_value);

	void teardown()
	{
    if (tcb)
      delete tcb;
		cut_remove_path(tmp_dir, NULL);
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
