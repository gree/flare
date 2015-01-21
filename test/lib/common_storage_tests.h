/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
/**
 *  common_storage_tests.h
 *
 *  @author Benjamin Surma <benjamin.surma@gree.net>
 *  @author Daniel Perez <tuvistavie@gmail.com>
 */

#include <storage.h>

using namespace gree::flare;

#define COMMON_STORAGE_TEST(storage_tester, testname) \
	void test_##testname() { \
		storage_tester->before_each(); \
		storage_tester->testname(); \
		storage_tester->after_each(); \
	}

/**
 *	Storage set test generation
 */

#define GENERATE_SET_TEST(tester, testname, type, version, noreply, behaviors) \
	void test_##testname() { \
		tester->before_each(); \
		tester->set_check(type, version, noreply, behaviors); \
		tester->after_each(); \
	}

#define GENERATE_SET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname, type, noreply, behaviors) \
	GENERATE_SET_TEST(tester, testname##_disabled, type, test_storage::storage_tester::vt_disabled, noreply, behaviors) \
	GENERATE_SET_TEST(tester, testname##_older, type, test_storage::storage_tester::vt_older, noreply, behaviors) \
	GENERATE_SET_TEST(tester, testname##_equal, type, test_storage::storage_tester::vt_equal, noreply, behaviors) \
	GENERATE_SET_TEST(tester, testname##_newer, type, test_storage::storage_tester::vt_newer, noreply, behaviors)

#define GENERATE_SET_TESTS_W_BEHAVIOR_TYPE(tester, testname, type, behaviors) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_noreply, type, true, behaviors) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_noreply_skiptime, type, true, behaviors | storage::behavior_skip_timestamp) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_noreply_skiplock, type, true, behaviors | storage::behavior_skip_lock) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_noreply_skiplock_skiptime, type, true, behaviors | storage::behavior_skip_lock | storage::behavior_skip_timestamp) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname, type, false, behaviors) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiptime, type, false, behaviors | storage::behavior_skip_timestamp) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock, type, false, behaviors | storage::behavior_skip_lock) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock_skiptime, type, false, behaviors | storage::behavior_skip_lock | storage::behavior_skip_timestamp) 

#define GENERATE_SET_TESTS_W_BEHAVIOR(tester, testname, behaviors) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE(tester, testname##_normal, test_storage::storage_tester::et_normal, behaviors) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE(tester, testname##_expired, test_storage::storage_tester::et_expired, behaviors) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE(tester, testname##_nonexistent, test_storage::storage_tester::et_nonexistent, behaviors) \
	GENERATE_SET_TESTS_W_BEHAVIOR_TYPE(tester, testname##_removed, test_storage::storage_tester::et_removed, behaviors)

#define GENERATE_SET_TESTS(tester) \
	GENERATE_SET_TESTS_W_BEHAVIOR(tester, set_none, 0) \
	GENERATE_SET_TESTS_W_BEHAVIOR(tester, set_append, storage::behavior_replace | storage::behavior_append) \
	GENERATE_SET_TESTS_W_BEHAVIOR(tester, set_prepend, storage::behavior_replace | storage::behavior_prepend) \
	GENERATE_SET_TESTS_W_BEHAVIOR(tester, set_add, storage::behavior_add) \
	GENERATE_SET_TESTS_W_BEHAVIOR(tester, set_replace, storage::behavior_replace) \
	GENERATE_SET_TESTS_W_BEHAVIOR(tester, set_cas, storage::behavior_cas) \
	GENERATE_SET_TESTS_W_BEHAVIOR(tester, set_touch, storage::behavior_touch) \
	GENERATE_SET_TESTS_W_BEHAVIOR(tester, set_dump, storage::behavior_dump)

/**
 *	Storage incr test generation
 */

#define GENERATE_INCR_TEST(tester, testname, is_incr, type, version, noreply, behaviors) \
	void test_##testname() { \
		tester->before_each(); \
		tester->incr_check(is_incr, type, version, noreply, behaviors); \
		tester->after_each(); \
	}

#define GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname, is_incr, type, noreply, behaviors) \
	GENERATE_INCR_TEST(tester, testname##_disabled, is_incr, type, test_storage::storage_tester::vt_disabled, noreply, behaviors) \
	GENERATE_INCR_TEST(tester, testname##_older, is_incr, type, test_storage::storage_tester::vt_older, noreply, behaviors) \
	GENERATE_INCR_TEST(tester, testname##_equal, is_incr, type, test_storage::storage_tester::vt_equal, noreply, behaviors) \
	GENERATE_INCR_TEST(tester, testname##_newer, is_incr, type, test_storage::storage_tester::vt_newer, noreply, behaviors)

#define GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE(tester, testname, is_incr, type) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_noreply, is_incr, type, true, 0) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_noreply_skiptime, is_incr, type, true, storage::behavior_skip_timestamp) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_noreply_skiplock, is_incr, type, true, storage::behavior_skip_lock) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_noreply_skiplock_skiptime, is_incr, type, true, storage::behavior_skip_lock | storage::behavior_skip_timestamp) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname, is_incr, type, false, 0) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiptime, is_incr, type, false, storage::behavior_skip_timestamp) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock, is_incr, type, false, storage::behavior_skip_lock) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock_skiptime, is_incr, type, false, storage::behavior_skip_lock | storage::behavior_skip_timestamp) 

#define GENERATE_INCR_TESTS_W_BEHAVIOR(tester, testname, is_incr) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE(tester, testname##_normal, is_incr, test_storage::storage_tester::et_normal) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE(tester, testname##_expired, is_incr, test_storage::storage_tester::et_expired) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE(tester, testname##_nonexistent, is_incr, test_storage::storage_tester::et_nonexistent) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE(tester, testname##_removed, is_incr, test_storage::storage_tester::et_removed) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE(tester, testname##_number, is_incr, test_storage::storage_tester::et_number) \
	GENERATE_INCR_TESTS_W_BEHAVIOR_TYPE(tester, testname##_zero, is_incr, test_storage::storage_tester::et_zero)

#define GENERATE_INCR_TESTS(tester) \
	GENERATE_INCR_TESTS_W_BEHAVIOR(tester, incr, true) \
	GENERATE_INCR_TESTS_W_BEHAVIOR(tester, decr, false)

/**
 *	Storage remove test generation
 */

#define GENERATE_REMOVE_TEST(tester, testname, type, version, behaviors) \
	void test_##testname() { \
		tester->before_each(); \
		tester->remove_check(type, version, behaviors); \
		tester->after_each(); \
	}

#define GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname, type, behaviors) \
	GENERATE_REMOVE_TEST(tester, testname##_disabled, type, test_storage::storage_tester::vt_disabled, behaviors) \
	GENERATE_REMOVE_TEST(tester, testname##_older, type, test_storage::storage_tester::vt_older, behaviors) \
	GENERATE_REMOVE_TEST(tester, testname##_equal, type, test_storage::storage_tester::vt_equal, behaviors) \
	GENERATE_REMOVE_TEST(tester, testname##_newer, type, test_storage::storage_tester::vt_newer, behaviors)

#define GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE(tester, testname, type) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname, type, 0) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock, type, storage::behavior_skip_lock) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiptime, type, storage::behavior_skip_timestamp) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skipversion, type, storage::behavior_skip_version) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock_skiptime, type, storage::behavior_skip_lock | storage::behavior_skip_timestamp) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock_skipversion, type, storage::behavior_skip_lock | storage::behavior_skip_version) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiptime_skipversion, type, storage::behavior_skip_timestamp | storage::behavior_skip_version) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock_skiptime_skipversion, type, storage::behavior_skip_lock | storage::behavior_skip_timestamp | storage::behavior_skip_version)

#define GENERATE_REMOVE_TESTS_W_BEHAVIOR(tester, testname) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE(tester, testname##_normal, test_storage::storage_tester::et_normal) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE(tester, testname##_expired, test_storage::storage_tester::et_expired) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE(tester, testname##_nonexistent, test_storage::storage_tester::et_nonexistent) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR_TYPE(tester, testname##_removed, test_storage::storage_tester::et_removed)

#define GENERATE_REMOVE_TESTS(tester) \
	GENERATE_REMOVE_TESTS_W_BEHAVIOR(tester, remove)

/**
 *	Storage remove test generation
 */

#define GENERATE_GET_TEST(tester, testname, type, version, behaviors) \
	void test_##testname() { \
		tester->before_each(); \
		tester->get_check(type, version, behaviors); \
		tester->after_each(); \
	}

#define GENERATE_GET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname, type, behaviors) \
	GENERATE_GET_TEST(tester, testname##_disabled, type, test_storage::storage_tester::vt_disabled, behaviors) \
	GENERATE_GET_TEST(tester, testname##_older, type, test_storage::storage_tester::vt_older, behaviors) \
	GENERATE_GET_TEST(tester, testname##_equal, type, test_storage::storage_tester::vt_equal, behaviors) \
	GENERATE_GET_TEST(tester, testname##_newer, type, test_storage::storage_tester::vt_newer, behaviors)

#define GENERATE_GET_TESTS_W_BEHAVIOR_TYPE(tester, testname, type) \
	GENERATE_GET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname, type, 0) \
	GENERATE_GET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock, type, storage::behavior_skip_lock) \
	GENERATE_GET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiptime, type, storage::behavior_skip_timestamp) \
	GENERATE_GET_TESTS_W_BEHAVIOR_TYPE_VERSION(tester, testname##_skiplock_skiptime, type, storage::behavior_skip_lock | storage::behavior_skip_timestamp)

#define GENERATE_GET_TESTS_W_BEHAVIOR(tester, testname) \
	GENERATE_GET_TESTS_W_BEHAVIOR_TYPE(tester, testname##_normal, test_storage::storage_tester::et_normal) \
	GENERATE_GET_TESTS_W_BEHAVIOR_TYPE(tester, testname##_expired, test_storage::storage_tester::et_expired) \
	GENERATE_GET_TESTS_W_BEHAVIOR_TYPE(tester, testname##_nonexistent, test_storage::storage_tester::et_nonexistent) \
	GENERATE_GET_TESTS_W_BEHAVIOR_TYPE(tester, testname##_removed, test_storage::storage_tester::et_removed)

#define GENERATE_GET_TESTS(tester) \
	GENERATE_GET_TESTS_W_BEHAVIOR(tester, get)

namespace test_storage
{

struct storage_helper : public storage {
	using storage::_mutex_slot_size;
	using storage::_mutex_slot;
};

class storage_tester
{
	public:
		storage_tester(storage* container);
		~storage_tester();

		enum entry_type { et_normal, et_expired, et_nonexistent, et_removed, et_number, et_zero };
		enum version_type { vt_disabled, vt_older, vt_equal, vt_newer };
		enum concurrent_test_type { ctt_add, ctt_replace, ctt_remove };

		void before_each();
		void after_each();

		// Specific tests
		void get_not_found();
		void set_basic();
		void set_empty_key();
		void set_space_key();
		void set_multiline_key();
		void set_key_too_long_for_memcached();
		void set_enormous_value();
		void remove_not_found();
		void remove_basic();
		void multiple_iter_begin();
		void iter_basic();
		void iter_non_initialized();
		void iter_end_error();
		void iter_next_concurrent_add() { iter_next_concurrent(ctt_add); }
		void iter_next_concurrent_replace() { iter_next_concurrent(ctt_replace); }
		void iter_next_concurrent_remove() { iter_next_concurrent(ctt_remove); }
		void truncate();
		void count();
		void append_keep_flag();
		void prepend_keep_flag();

		void set_check(entry_type type, version_type version, bool noreply, int behaviors);
		void incr_check(bool is_incr, entry_type type, version_type version, bool noreply, int behaviors);
		void remove_check(entry_type type, version_type version, int behaviors);
		void get_check(entry_type type, version_type version, int behaviors);

		// Helper functions
		storage::result get(const std::string &key, std::string &data, int* flag  = 0, int* version = 0, int b = 0);
		storage::result set(const std::string &key, const std::string &data, int flag = 0, int version = 0);
		storage::result remove(const std::string &key, int b = 0);
		static storage::entry make_entry(const std::string &key, const std::string &value);
		static storage::entry make_entry(entry_type type);
		static std::string get_type_key(entry_type type);
		static std::string get_type_value(entry_type type);
		static std::string get_entry_value(storage::entry& entry);

	protected:
		storage* _container;
		storage_helper* _helper;
		int _current_entries_nb;

		void lock_entry(storage::entry& e, bool write = true);
		void unlock_entry(storage::entry& e);

		storage::entry prepare_set_operation(entry_type type, version_type version, bool noreply, int behaviors);
		void end_set_operation(storage::entry& e, int behaviors);

		void perform_add_check(storage::entry&, entry_type, version_type, int);
		void perform_replace_check(storage::entry&, entry_type, version_type, int);
		void perform_append_prepend_check(storage::entry&, entry_type, version_type, int);
		void perform_cas_check(storage::entry&, entry_type, version_type, int); 
		void perform_set_check(storage::entry&, entry_type, version_type, int);
		void perform_touch_check(storage::entry&, entry_type, version_type, int);
		void perform_dump_check(storage::entry&, entry_type, version_type, int);
		void perform_incr_check(storage::entry&, bool is_incr, entry_type, version_type, int);
		void iter_next_concurrent(concurrent_test_type type);
};

}	// namespace test_storage
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
