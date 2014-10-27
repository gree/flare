/**
 *	test_storage_entry.cc
 *
 *	Note: There are no parser tests for storage::parse_type_get,
 *	since it does not appear to be used anywhere in the code.
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <storage.h>

using namespace gree::flare;

namespace test_storage_entry
{
	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	storage::entry parse_entry(const std::string& input, storage::parse_type parse_type, int expected)
	{
		stats_object->update_timestamp();
		storage::entry entry;
		int parse_result = entry.parse(input.c_str(), parse_type);
		cut_assert_equal_int(expected, parse_result);
		return entry;
	}

	storage::entry parse_entry_cas_base_test(const std::string& additional_input = std::string(), int expected = 0)
	{
		std::string input = " key 3 10 50 5 " + additional_input;
		storage::entry entry = parse_entry(input, storage::parse_type_cas, expected);
		cut_assert_equal_string("key", entry.key.c_str());
		cut_assert_equal_int(3, entry.flag);
		cut_assert_equal_double(stats_object->get_timestamp() + 10, 2, entry.expire);
		cut_assert_equal_int(50, entry.size);
		cut_assert_equal_int(5, entry.version);
		return entry;
	}

	void test_parse_entry_cas_base()
	{
		storage::entry entry = parse_entry_cas_base_test();
		cut_assert_equal_int(storage::option_none, entry.option);
	}

	void test_parse_entry_cas_option_noreply()
	{
		storage::entry entry = parse_entry_cas_base_test("noreply");
		cut_assert_equal_int(storage::option_noreply, entry.option);
	}

	void test_parse_entry_cas_option_sync()
	{
		storage::entry entry = parse_entry_cas_base_test("sync");
		cut_assert_equal_int(storage::option_sync, entry.option);
	}

	void test_parse_entry_cas_option_async()
	{
		storage::entry entry = parse_entry_cas_base_test("async");
		cut_assert_equal_int(storage::option_async, entry.option);
	}

	void test_parse_entry_cas_options()
	{
		storage::entry entry = parse_entry_cas_base_test("noreply sync");
		cut_assert_equal_int(storage::option_noreply | storage::option_sync, entry.option);
	}

	storage::entry parse_entry_delete_base_test(const std::string& additional_input = std::string(), int expected = 0)
	{
		std::string input = " key " + additional_input;
		storage::entry entry = parse_entry(input, storage::parse_type_delete, expected);
		cut_assert_equal_string("key", entry.key.c_str());
		cut_assert_equal_int(0, entry.flag);
		cut_assert_equal_int(0, entry.size);
		return entry;
	}

	void test_parse_entry_delete_base()
	{
		storage::entry entry = parse_entry_delete_base_test();
		cut_assert_equal_int(0, entry.expire);
		cut_assert_equal_int(0, entry.version);
		cut_assert_equal_int(storage::option_none, entry.option);
	}

	void test_parse_entry_delete_options()
	{
		{
			storage::entry entry = parse_entry_delete_base_test("noreply");
			cut_assert_equal_int(0, entry.expire);
			cut_assert_equal_int(0, entry.version);
			cut_assert_equal_int(storage::option_noreply, entry.option);
		}
		{
			storage::entry entry = parse_entry_delete_base_test("sync");
			cut_assert_equal_int(0, entry.expire);
			cut_assert_equal_int(0, entry.version);
			cut_assert_equal_int(storage::option_sync, entry.option);
		}
		{
			storage::entry entry = parse_entry_delete_base_test("sync");
			cut_assert_equal_int(0, entry.expire);
			cut_assert_equal_int(0, entry.version);
			cut_assert_equal_int(storage::option_sync, entry.option);
		}
		{
			storage::entry entry = parse_entry_delete_base_test("noreply async");
			cut_assert_equal_int(0, entry.expire);
			cut_assert_equal_int(0, entry.version);
			cut_assert_equal_int(storage::option_noreply | storage::option_async, entry.option);
		}
	}

	void test_parse_entry_delete_expire()
	{
		storage::entry entry = parse_entry_delete_base_test("20");
		cut_assert_equal_double(stats_object->get_timestamp() + 20, 2, entry.expire);
		cut_assert_equal_int(0, entry.version);
		cut_assert_equal_int(storage::option_none, entry.option);
	}

	void test_parse_entry_delete_expire_version()
	{
		storage::entry entry = parse_entry_delete_base_test("20 5");
		cut_assert_equal_double(stats_object->get_timestamp() + 20, 2, entry.expire);
		cut_assert_equal_int(5, entry.version);
		cut_assert_equal_int(storage::option_none, entry.option);
	}

	void test_parse_entry_delete_expire_version_options()
	{
		{
			storage::entry entry = parse_entry_delete_base_test("20 5 noreply");
			cut_assert_equal_double(stats_object->get_timestamp() + 20, 2, entry.expire);
			cut_assert_equal_int(5, entry.version);
			cut_assert_equal_int(storage::option_noreply, entry.option);
		}
		{
			storage::entry entry = parse_entry_delete_base_test("20 5 sync");
			cut_assert_equal_double(stats_object->get_timestamp() + 20, 2, entry.expire);
			cut_assert_equal_int(5, entry.version);
			cut_assert_equal_int(storage::option_sync, entry.option);
		}
		{
			storage::entry entry = parse_entry_delete_base_test("20 5 async");
			cut_assert_equal_double(stats_object->get_timestamp() + 20, 2, entry.expire);
			cut_assert_equal_int(5, entry.version);
			cut_assert_equal_int(storage::option_async, entry.option);
		}
		{
			storage::entry entry = parse_entry_delete_base_test("20 5 noreply async");
			cut_assert_equal_double(stats_object->get_timestamp() + 20, 2, entry.expire);
			cut_assert_equal_int(5, entry.version);
			cut_assert_equal_int(storage::option_noreply | storage::option_async, entry.option);
		}
	}

	storage::entry parse_entry_set_base_test(const std::string& additional_input = std::string(), int expected = 0)
	{
		std::string input = " key 5 60 100 " + additional_input;
		storage::entry entry = parse_entry(input, storage::parse_type_set, expected);
		cut_assert_equal_string("key", entry.key.c_str());
		cut_assert_equal_int(5, entry.flag);
		cut_assert_equal_double(stats_object->get_timestamp() + 60, 2, entry.expire);
		cut_assert_equal_int(100, entry.size);
		return entry;
	}

	void test_parse_entry_set_base()
	{
		storage::entry entry = parse_entry_set_base_test();
		cut_assert_equal_int(0, entry.version);
		cut_assert_equal_int(storage::option_none, entry.option);
	}

	void test_parse_entry_set_options()
	{
		{
			storage::entry entry = parse_entry_delete_base_test("noreply");
			cut_assert_equal_int(0, entry.version);
			cut_assert_equal_int(storage::option_noreply, entry.option);
		}
		{
			storage::entry entry = parse_entry_delete_base_test("sync");
			cut_assert_equal_int(0, entry.version);
			cut_assert_equal_int(storage::option_sync, entry.option);
		}
		{
			storage::entry entry = parse_entry_delete_base_test("sync");
			cut_assert_equal_int(0, entry.version);
			cut_assert_equal_int(storage::option_sync, entry.option);
		}
		{
			storage::entry entry = parse_entry_delete_base_test("noreply async");
			cut_assert_equal_int(0, entry.version);
			cut_assert_equal_int(storage::option_noreply | storage::option_async, entry.option);
		}
	}

	void test_parse_entry_set_version()
	{
		storage::entry entry = parse_entry_set_base_test("10");
		cut_assert_equal_int(10, entry.version);
		cut_assert_equal_int(storage::option_none, entry.option);
	}

	void test_parse_entry_set_version_options()
	{
		{
			storage::entry entry = parse_entry_set_base_test("10 noreply");
			cut_assert_equal_int(10, entry.version);
			cut_assert_equal_int(storage::option_noreply, entry.option);
		}
		{
			storage::entry entry = parse_entry_set_base_test("10 sync");
			cut_assert_equal_int(10, entry.version);
			cut_assert_equal_int(storage::option_sync, entry.option);
		}
		{
			storage::entry entry = parse_entry_set_base_test("10 sync");
			cut_assert_equal_int(10, entry.version);
			cut_assert_equal_int(storage::option_sync, entry.option);
		}
		{
			storage::entry entry = parse_entry_set_base_test("10 noreply async");
			cut_assert_equal_int(10, entry.version);
			cut_assert_equal_int(storage::option_noreply | storage::option_async, entry.option);
		}
	}

	storage::entry parse_entry_touch_base_test(const std::string& additional_input = std::string(), int expected = 0)
	{
		std::string input = " key 3600 " + additional_input;
		storage::entry entry = parse_entry(input, storage::parse_type_set, expected);
		cut_assert_equal_string("key", entry.key.c_str());
		cut_assert_equal_int(0, entry.flag);
		cut_assert_equal_int(0, entry.version);
		cut_assert_equal_double(stats_object->get_timestamp() + 3600, 2, entry.expire);
		cut_assert_equal_int(0, entry.size);
		return entry;
	}
	
	void test_parse_entry_touch_base()
	{
		storage::entry entry = parse_entry_set_base_test();
		cut_assert_equal_int(storage::option_none, entry.option);
	}

	void test_parse_entry_touch_noreply()
	{
		storage::entry entry = parse_entry_set_base_test("noreply");
		cut_assert_equal_int(storage::option_noreply, entry.option);
	}

	void test_parse_entry_abonormal_negative_flag()
	{
		std::string input = " key -1 0 1";
		storage::entry entry = parse_entry(input, storage::parse_type_set, -1);
	}

	void test_parse_entry_abonormal_exceed_flag()
	{
		// maximum check
		std::string input = " key 4294967295 0 1";
		storage::entry entry = parse_entry(input, storage::parse_type_set, 0);
		cut_assert_equal_string("key", entry.key.c_str());
		cut_assert_equal_int(4294967295, entry.flag);

		// over 32 bit max
		input = " key 4294967296 0 1";
		parse_entry(input, storage::parse_type_set, -1);
	}

	void test_parse_entry_abnormal_string_flag()
	{
		std::string input = " key flag 0 1";
		parse_entry(input, storage::parse_type_set, -1);
	}

	void test_parse_entry_abnormal_negative_expire()
	{
		std::string input = " key 0 -1 1";
		parse_entry(input, storage::parse_type_set, -1);
	}

	void test_parse_entry_abnormal_string_expire()
	{
		std::string input = " key 0 expire 1";
		parse_entry(input, storage::parse_type_set, -1);
	}

	void test_parse_entry_abnormal_negative_size()
	{
		std::string input = " key 0 0 -1";
		parse_entry(input, storage::parse_type_set, -1);
	}

	void test_parse_entry_abnormal_exceeded_size()
	{
		// maximum check
		std::string input = " key 0 0 " + boost::lexical_cast<std::string>(storage::entry::max_data_size);
		storage::entry entry = parse_entry(input, storage::parse_type_set, 0);
		cut_assert_equal_string("key", entry.key.c_str());
		cut_assert_equal_int(storage::entry::max_data_size, entry.size);

		// over max_data_size
		input = "key 0 0 " + boost::lexical_cast<std::string>(storage::entry::max_data_size + 1);
		parse_entry(input, storage::parse_type_set, -1);
	}

	void test_parse_entry_abnormal_string_size()
	{
		std::string input = " key 0 0 size";
		parse_entry(input, storage::parse_type_set, -1);
	}

	void test_parse_entry_abnormal_negative_version()
	{
		std::string input = " key 0 0 1 -1";
		parse_entry(input, storage::parse_type_set, -1);
	}

	void test_parse_entry_abnormal_string_version()
	{
		std::string input = " key 0 0 1 version";
		parse_entry(input, storage::parse_type_set, -1);
	}

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
