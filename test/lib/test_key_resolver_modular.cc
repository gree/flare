/**
 *	test_key_resolver_modular.cc
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 */
#include <sys/stat.h>
#include <sys/types.h>

#include <cppcutter.h>

#include <cluster.h>
#include <key_resolver_modular.h>
#include <storage.h>

using namespace std;
using namespace gree::flare;

namespace test_key_resolver_modular {
	key_resolver*		kr;

	void setup() {
		kr = new key_resolver_modular(1024, 1, 4096);
		kr->startup();
	}

	void teardown() {
		delete kr;
	}

	void test_partition() {
		storage::entry e;
		int r;

		int test_key1_assert[] = {0, 0, 2, 2, 2, 5, 5, 5};
		for (int i = 0; i < sizeof(test_key1_assert) / sizeof(int); i++) {
			r = kr->resolve(e.get_key_hash_value("test_key1", storage::hash_algorithm_simple), i+1);
			cut_assert_equal_int(test_key1_assert[i], r);
		}

		int test_key2_assert[] = {0, 0, 0, 0, 0, 5, 5, 5};
		for (int i = 0; i < sizeof(test_key2_assert) / sizeof(int); i++) {
			r = kr->resolve(e.get_key_hash_value("::test::key::1979", storage::hash_algorithm_simple), i+1);
			cut_assert_equal_int(test_key2_assert[i], r);
		}

		int test_key3_assert[] = {0, 0, 2, 2, 2, 2, 2, 2};
		for (int i = 0; i < sizeof(test_key3_assert) / sizeof(int); i++) {
			r = kr->resolve(e.get_key_hash_value("::test::key::19790217", storage::hash_algorithm_simple), i+1);
			cut_assert_equal_int(test_key3_assert[i], r);
		}
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
