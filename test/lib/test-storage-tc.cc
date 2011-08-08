/**
 *	test-storage-tc.cc
 *
 *	@author	Kouhei Sutou <kou@clear-code.com>
 */

#include <sys/stat.h>
#include <sys/types.h>

#include <cppcutter.h>

#include <storage_tch.h>

using namespace std;
using namespace gree::flare;

namespace test_storage
{
    const char tmp_dir[] = "tmp";
    storage_tch *storage;

    void setup()
    {
        const char *db_dir;
        storage = NULL;

        // db_dir = cut_build_path(tmp_dir, "storage", "tc", NULL);
        db_dir = tmp_dir;
        mkdir(db_dir, 0700);
        string compress("");
        storage = new storage_tch(db_dir,
                                  32,
                                  4,
                                  131071,
                                  65536,
                                  compress,
                                  true,
																	0);
        storage->open();
    }

    void teardown()
    {
        if (storage)
            delete storage;
        cut_remove_path(tmp_dir, NULL);
    }

    void test_set_and_get()
    {
        storage::entry entry;
        std::string name("Bob");
        storage::result result;
        entry.key = "name";
        entry.size = name.length() + 1;
        entry.data = gree::flare::shared_byte(new uint8_t(entry.size));
        memcpy(entry.data.get(), name.c_str(), entry.size);
        cppcut_assert_equal(0, storage->set(entry, result));

        storage::entry new_entry;
        new_entry.key = "name";
        cppcut_assert_equal(0, storage->get(new_entry, result));
        char actual_name_c_str[new_entry.size];
        memcpy(actual_name_c_str, new_entry.data.get(), new_entry.size);
        string actual_name(actual_name_c_str);
        cppcut_assert_equal(name, actual_name);
    }
}
