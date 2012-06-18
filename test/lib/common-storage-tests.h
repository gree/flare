/**
 *	common-storage-tests.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <storage.h>

using namespace gree::flare;

#define COMMON_STORAGE_TEST(storage, testname) \
  void test_##storage##_##testname() { \
    test_storage::testname(storage); \
  }

namespace test_storage
{
  // Common tests
	void get_not_found(storage*);
	void set_basic(storage*);
	void set_empty_key(storage*);
	void set_space_key(storage*);
	void set_multiline_key(storage*);
	void set_key_too_long_for_memcached(storage*);
	void set_enormous_value(storage*);

  // Helper functions
  storage::result get(storage*, const std::string& key, std::string& data, int b = 0);
	storage::result set(storage*, const std::string& key, const std::string& data, int b = 0);
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
