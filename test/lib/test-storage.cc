/**
 *	test-storage.cc
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 */

#include <cppcutter.h>

#include <storage.h>

#define BSFT(r,c) ((int)((r)*37+(c)))
#define ABS(r) (((r)>=0)?(r):-(r))

using namespace std;
using namespace gree::flare;

namespace test_storage
{
	void setup()
	{
	}

	void teardown()
	{
	}

	void test_hash_algorithm_simple()
	{
		storage::hash_algorithm ha = storage::hash_algorithm_simple;
		storage::entry e;
		e.key = "";
		cppcut_assert_equal(0, e.get_key_hash_value("", ha));
		cppcut_assert_equal(55, e.get_key_hash_value("\1\2\3\4\5\6\7\10\11\12", ha));
		cppcut_assert_equal(ABS(70+108+97+114+101),	e.get_key_hash_value("Flare", ha));
		cppcut_assert_equal(0, e.get_key_hash_value("\0NOTUSED", ha));
	}

	void test_hash_algorithm_bitshift()
	{
		storage::hash_algorithm ha = storage::hash_algorithm_bitshift;
		storage::entry e;
		e.key = "";
		cppcut_assert_equal(19790217, e.get_key_hash_value("", ha));
		cppcut_assert_equal(ABS(BSFT(BSFT(BSFT(BSFT(BSFT(BSFT(19790217, 1), 2), 3), 4), 5), 6)),
												e.get_key_hash_value("\1\2\3\4\5\6", ha));
		cppcut_assert_equal(ABS(BSFT(BSFT(BSFT(BSFT(BSFT(19790217, 70), 108), 97), 114), 101)),
												e.get_key_hash_value("Flare", ha));
		cppcut_assert_equal(19790217, e.get_key_hash_value("\0NOTUSED", ha));
	}

	void test_hash_algorithm_crc32()
	{
		storage::hash_algorithm ha = storage::hash_algorithm_crc32;
		storage::entry e;
		e.key = "";
		cppcut_assert_equal(0, e.get_key_hash_value("", ha));
		cppcut_assert_equal(161824251, e.get_key_hash_value("Flare", ha));
		cppcut_assert_equal((int)(-3489101255LL&0xffffffffLL),
												e.get_key_hash_value("MINUS", ha));
		cppcut_assert_equal(0, e.get_key_hash_value("\0NOTUSED", ha));
	}

	void test_hash_algorithm_adler32()
	{
		storage::hash_algorithm ha = storage::hash_algorithm_adler32;
		storage::entry e;
		e.key = "";
		cppcut_assert_equal(1, e.get_key_hash_value("", ha));
		cppcut_assert_equal(92209643, e.get_key_hash_value("Flare", ha));
		cppcut_assert_equal((int)(-3827502261LL&0xffffffffLL),
												e.get_key_hash_value("MINUSminusMINUSminusMINUSminusMINUS", ha));
		cppcut_assert_equal(1, e.get_key_hash_value("\0NOTUSED", ha));
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
