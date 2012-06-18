/**
 *	common-storage-tests.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include <common-storage-tests.h>

using namespace gree::flare;

namespace test_storage
{
	// Helper function to get a given key
	storage::result get(storage* container, const std::string& key, std::string& data, int b)
	{
		storage::result result;
		storage::entry entry;
		entry.key = key;
		cppcut_assert_equal(0, container->get(entry, result));
		if (entry.size > 0) {
			char entry_c_str[entry.size];
			memcpy(entry_c_str, entry.data.get(), entry.size);
			data.assign(entry_c_str, entry.size);
		}
		return result;
	}

	// Helper function to set a key to a given value
	storage::result set(storage* container, const std::string& key, const std::string& data, int b)
	{
		storage::result result;
		storage::entry entry;
		entry.key = key;
		entry.size = data.length();
		entry.data = shared_byte(new uint8_t[entry.size]);
		memcpy(entry.data.get(), data.c_str(), entry.size);
		cppcut_assert_equal(0, container->set(entry, result));
		return result;
	}

	void get_not_found(storage* container)
	{
		std::string dummy;
		cut_assert(storage::result_not_found == get(container, "does_not_exist", dummy));
	}

	void set_basic(storage* container)
	{
		std::string key = "name";
		std::string data = "Bob";
		cut_assert(storage::result_stored == set(container, key, data));

		std::string stored_data;
		cut_assert(storage::result_none == get(container, key, stored_data));
		cppcut_assert_equal(data, stored_data);
	}

	void set_empty_key(storage* container)
	{
		std::string empty_key;
		std::string data = "empty";
		cut_assert(storage::result_stored == set(container, empty_key, data));

		std::string stored_data;
		cut_assert(storage::result_none == get(container, empty_key, stored_data));
		cppcut_assert_equal(data, stored_data);
	}

	void set_space_key(storage* container)
	{
		std::string space_key = "oh look, spaces!";
		std::string data = "space";
		cut_assert(storage::result_stored == set(container, space_key, data));

		std::string stored_data;
		cut_assert(storage::result_none == get(container, space_key, stored_data));
		cppcut_assert_equal(data, stored_data);
	}

	void set_multiline_key(storage* container)
	{
		std::string space_key = "oh look,\r\na new line!";
		std::string data = "multiline";
		cut_assert(storage::result_stored == set(container, space_key, data));

		std::string stored_data;
		cut_assert(storage::result_none == get(container, space_key, stored_data));
		cppcut_assert_equal(data, stored_data);
	}

	void set_key_too_long_for_memcached(storage* container)
	{
		// In memcached, key size is stored in a uint8_t
		std::string long_key(std::numeric_limits<uint8_t>::max() * 2, 'l');
		std::string data = "long";
		cut_assert(storage::result_stored == set(container, long_key, data));

		std::string stored_data;
		cut_assert(storage::result_none == get(container, long_key, stored_data));
		cppcut_assert_equal(data, stored_data);

		// If this were memcached, we would fetch the same key below:
		std::string not_so_long_key(std::numeric_limits<uint8_t>::max(), 'l');
		cut_assert(storage::result_not_found == get(container, not_so_long_key, stored_data));
	}

	void set_enormous_value(storage* container)
	{
		// In memcached, values are limited to 1M
		std::string key = "long";
		std::string long_data(2 * 1024 * 1024 /* 2 MB */, 'l');
		cut_assert(storage::result_stored == set(container, key, long_data));

		std::string stored_data;
		cut_assert(storage::result_none == get(container, key, stored_data));
		cppcut_assert_equal(long_data, stored_data);
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
