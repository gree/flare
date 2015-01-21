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
 *  common_storage_tests.cc
 *
 *  @author Benjamin Surma <benjamin.surma@gree.net>
 *  @author Daniel Perez <tuvistavie@gmail.com>
 */

#include <cppcutter.h>

#include <common_storage_tests.h>
#include "stats.h"
#include <app.h>

#include <limits>

#if (defined(HAVE_VALGRIND_H))
#	include <valgrind.h>
#elif (defined(HAVE_VALGRIND_VALGRIND_H))
#	include <valgrind/valgrind.h>
#else
#	define RUNNING_ON_VALGRIND 0
#endif

using namespace gree::flare;

namespace test_storage {

static int default_version = 2;

storage_tester::storage_tester(storage *container):
	_container(container),
	_helper(static_cast<storage_helper*>(container)),
	_current_entries_nb(0) {
		_container->open();
}

storage_tester::~storage_tester() {
	delete this->_container;
}

// Helper function to get a given key
storage::result storage_tester::get(const std::string &key, std::string &value, int *flag, int *version, int b)  {
	storage::result result;
	storage::entry entry;
	entry.key = key;
	cut_assert_equal_int(0, this->_container->get(entry, result, b));
	// if entry is expired, entry.size > 0 but entry.data == NULL
	if (entry.size > 0 && entry.data != NULL) {
		value.assign(reinterpret_cast<const char *>(entry.data.get()), entry.size);
		if (flag)
			*flag = entry.flag;
		if (version)
			*version = entry.version;
	}
	return result;
}

// Helper function to set a key to a given value
storage::result storage_tester::set(const std::string &key, const std::string &value, int flag, int behavior) {
	storage::result result;
	storage::entry entry;
	entry.key = key;
	entry.flag = flag;
	entry.size = value.size();
	entry.data = shared_byte(new uint8_t[entry.size]);
	memcpy(entry.data.get(), value.data(), entry.size);
	cut_assert_equal_int(0, this->_container->set(entry, result, behavior));
	return result;
}

storage::result storage_tester::remove(const std::string &key, int b) {
	storage::result result;
	storage::entry entry;
	entry.key = key;
	cut_assert_equal_int(0, this->_container->remove(entry, result));
	return result;
}

std::string storage_tester::get_type_key(entry_type type) {
	switch (type) {
		case et_normal: return "normal";
		case et_expired: return "expired";
		case et_nonexistent: return "nonexistent";
		case et_removed: return "removed";
		case et_number: return "number";
		case et_zero: return "zero";
	}
}

std::string storage_tester::get_type_value(entry_type type) {
	switch (type) {
		case et_normal: return "normal";
		case et_expired: return "expired";
		case et_nonexistent: return "nonexistent";
		case et_removed: return "removed";
		case et_number: return "25";
		case et_zero: return "0";
	}
}

storage::entry storage_tester::make_entry(const std::string &key, const std::string &value) {
	storage::entry entry;
	entry.key = key;
	entry.size = value.size();
	entry.data = shared_byte(new uint8_t[entry.size]);
	memcpy(entry.data.get(), value.data(), entry.size);
	entry.version = default_version;
	return entry;
}

storage::entry storage_tester::make_entry(entry_type type) {
	storage::entry entry = make_entry(get_type_key(type), get_type_value(type));
	switch (type) {
		case et_expired:
			entry.expire = 1;
			break;
		case et_removed:
			entry.expire = util::realtime(3600); // now + 1h
			break;
		default:
			entry.expire = 0;
			break;
	}
	return entry;
}

std::string storage_tester::get_entry_value(storage::entry &entry) {
	std::string value;
	value.assign(reinterpret_cast<char*>(entry.data.get()), entry.size);
	return value;
}

void storage_tester::lock_entry(storage::entry &e, bool write) {
	int mutex_index = e.get_key_hash_value(storage::hash_algorithm_murmur) % this->_helper->_mutex_slot_size;
	if (write) {
		pthread_rwlock_wrlock(&this->_helper->_mutex_slot[mutex_index]);
	} else {
		pthread_rwlock_rdlock(&this->_helper->_mutex_slot[mutex_index]);
	}
}

void storage_tester::unlock_entry(storage::entry &e) {
	int mutex_index = e.get_key_hash_value(storage::hash_algorithm_murmur) % this->_helper->_mutex_slot_size;
	pthread_rwlock_unlock(&this->_helper->_mutex_slot[mutex_index]);
}

void storage_tester::before_each() {
	cut_assert_not_null(this->_container);
	
	storage::result result;
	storage::entry entry = make_entry(et_normal);
	cut_assert_equal_int(0, this->_container->set(entry, result, storage::behavior_skip_version));
	cut_assert_equal_int(storage::result_stored, result);
	this->_current_entries_nb++;

	entry = make_entry(et_expired);
	cut_assert_equal_int(0, this->_container->set(entry, result, storage::behavior_skip_version | storage::behavior_skip_timestamp));
	cut_assert_equal_int(storage::result_stored, result);
	cut_assert_equal_int(static_cast<time_t>(1), entry.expire);
	this->_current_entries_nb++;

	entry = make_entry(et_removed);
	cut_assert_equal_int(0, this->_container->set(entry, result, storage::behavior_skip_version));
	cut_assert_equal_int(storage::result_stored, result);
	cut_assert_equal_int(0, this->_container->remove(entry, result, storage::behavior_skip_version));
	cut_assert_equal_int(storage::result_deleted, result);

	entry = make_entry(et_number);
	cut_assert_equal_int(0, this->_container->set(entry, result, storage::behavior_skip_version));
	cut_assert_equal_int(storage::result_stored, result);
	this->_current_entries_nb++;

	entry = make_entry(et_zero);
	cut_assert_equal_int(0, this->_container->set(entry, result, storage::behavior_skip_version));
	cut_assert_equal_int(storage::result_stored, result);
	this->_current_entries_nb++;
}

void storage_tester::after_each() {
	cut_assert_equal_int(0, this->_container->truncate(storage::behavior_skip_lock));
	this->_current_entries_nb = 0;
	cut_assert_equal_int(this->_current_entries_nb, this->_container->count());
}

void storage_tester::get_not_found() {
	std::string dummy;
	cut_assert_equal_int(storage::result_not_found, this->get("does_not_exist", dummy));
}

void storage_tester::set_basic() {
	std::string key = get_type_key(et_normal);
	std::string data = "foo";
	cut_assert_equal_int(storage::result_stored, this->set(key, data));

	std::string stored_data;
	cut_assert_equal_int(storage::result_none, this->get(key, stored_data));
	cut_assert_equal_string(data.c_str(), stored_data.c_str());
}

void storage_tester::set_empty_key() {
	std::string empty_key;
	std::string data = "empty";
	cut_assert_equal_int(storage::result_stored, this->set(empty_key, data));

	std::string stored_data;
	cut_assert_equal_int(storage::result_none, this->get(empty_key, stored_data));
	cut_assert_equal_string(data.c_str(), stored_data.c_str());
}

void storage_tester::set_space_key() {
	std::string space_key = "oh look, spaces!";
	std::string data = "space";
	cut_assert_equal_int(storage::result_stored, this->set(space_key, data));

	std::string stored_data;
	cut_assert_equal_int(storage::result_none, this->get(space_key, stored_data));
	cut_assert_equal_string(data.c_str(), stored_data.c_str());
}

void storage_tester::set_multiline_key() {
	std::string space_key = "oh look,\r\na new line!";
	std::string data = "multiline";

	cut_assert_equal_int(storage::result_stored, this->set(space_key, data));

	std::string stored_data;
	cut_assert_equal_int(storage::result_none, this->get(space_key, stored_data));
	cut_assert_equal_string(data.c_str(), stored_data.c_str());
}

void storage_tester::set_key_too_long_for_memcached() {
	// In memcached, key size is stored in a uint8_t
	std::string long_key(std::numeric_limits<uint8_t>::max() * 2, 'l');
	std::string data = "long";
	cut_assert_equal_int(storage::result_stored, this->set(long_key, data));

	std::string stored_data;
	cut_assert_equal_int(storage::result_none, this->get(long_key, stored_data));
	cut_assert_equal_string(data.c_str(), stored_data.c_str());

	// If this were memcached, we would fetch the same key below:
	std::string not_so_long_key(std::numeric_limits<uint8_t>::max(), 'l');
	cut_assert_equal_int(storage::result_not_found, this->get(not_so_long_key, stored_data));
}

void storage_tester::set_enormous_value() {
	// In memcached, values are limited to 1M
	std::string key = "long";
	std::string long_data(2 * 1024 * 1024 /* 2 MB */, 'l');
	cut_assert_equal_int(storage::result_stored, this->set(key, long_data));

	std::string stored_data;
	cut_assert_equal_int(storage::result_none, this->get(key, stored_data));
	cut_assert_equal_string(long_data.c_str(), stored_data.c_str());
}

void storage_tester::append_keep_flag() {
	// Set value "append" "value" 5
	std::string key = "append";
	cut_assert_equal_int(storage::result_stored, this->set(key, "value", 5));
	std::string value;
	int flag;
	int version;
	cut_assert_equal_int(storage::result_none, this->get(key, value, &flag, &version));
	cut_assert_equal_string("value", value.c_str());
	cut_assert_equal_int(5, flag);
	cut_assert_equal_int(1, version);
	// Append with new flag
	cut_assert_equal_int(storage::result_stored, this->set(key, "_post", 10, storage::behavior_append));
	// Check new value and flag
	cut_assert_equal_int(storage::result_none, this->get(key, value, &flag, &version));
	cut_assert_equal_string("value_post", value.c_str());
	cut_assert_equal_int(5, flag); // New value is ignored
	cut_assert_equal_int(2, version); // Version has been incremented
}

void storage_tester::prepend_keep_flag() {
	// Set value "prepend" "value" 5
	std::string key = "prepend";
	cut_assert_equal_int(storage::result_stored, this->set(key, "value", 5));
	std::string value;
	int flag;
	int version;
	cut_assert_equal_int(storage::result_none, this->get(key, value, &flag, &version));
	cut_assert_equal_string("value", value.c_str());
	cut_assert_equal_int(5, flag);
	// prepend with new flag
	cut_assert_equal_int(storage::result_stored, this->set(key, "pre_", 10, storage::behavior_prepend));
	// Check new value and flag
	cut_assert_equal_int(storage::result_none, this->get(key, value, &flag, &version));
	cut_assert_equal_string("pre_value", value.c_str());
	cut_assert_equal_int(5, flag); // New value is ignored
	cut_assert_equal_int(2, version); // Version has been incremented
}

void storage_tester::remove_not_found() {
	cut_assert_equal_int(storage::result_not_found, this->remove("does_not_exist"));
}

void storage_tester::remove_basic() {
	set_basic();
	cut_assert_equal_int(storage::result_deleted, this->remove(get_type_key(et_normal)));
	std::string dummy;
	cut_assert_equal_int(storage::result_not_found, this->get(get_type_key(et_normal), dummy));
}

void storage_tester::multiple_iter_begin() {
	cut_assert_equal_int(0, this->_container->iter_begin());
	cut_assert_equal_int(-1, this->_container->iter_begin());
	cut_assert_equal_int(0, this->_container->iter_end());
}

void storage_tester::iter_basic() {
	truncate();
	std::set<std::string> stored_keys;
	stored_keys.insert("A");
	stored_keys.insert("B");
	stored_keys.insert("C");
	stored_keys.insert("D");
	stored_keys.insert("E");
	for (std::set<std::string>::const_iterator it = stored_keys.begin(); it != stored_keys.end(); ++it) {
		storage::entry entry = make_entry(*it, *it);
		storage::result result;
		cut_assert_equal_int(0, this->_container->set(entry, result, 0));
		cut_assert_equal_int(storage::result_stored, result);
	}
	std::set<std::string> fetched_keys;
	std::string fetched_key;
	cut_assert_equal_int(0, this->_container->iter_begin());
	cut_assert_equal_int(storage::iteration_continue, this->_container->iter_next(fetched_key));
	fetched_keys.insert(fetched_key);
	cut_assert_equal_int(storage::iteration_continue, this->_container->iter_next(fetched_key));
	fetched_keys.insert(fetched_key);
	cut_assert_equal_int(storage::iteration_continue, this->_container->iter_next(fetched_key));
	fetched_keys.insert(fetched_key);
	cut_assert_equal_int(storage::iteration_continue, this->_container->iter_next(fetched_key));
	fetched_keys.insert(fetched_key);
	cut_assert_equal_int(storage::iteration_continue, this->_container->iter_next(fetched_key));
	fetched_keys.insert(fetched_key);
	std::string empty;
	cut_assert_equal_int(storage::iteration_end, this->_container->iter_next(empty));
	cut_assert_equal_int(0, empty.size());
	cut_assert_equal_int(0, this->_container->iter_end());
	cut_assert_equal_int(stored_keys.size(), fetched_keys.size());
	cut_assert(stored_keys == fetched_keys);
}

void storage_tester::iter_non_initialized() {
	std::string tmp;
	cut_assert_equal_int(storage::iteration_error, this->_container->iter_next(tmp));
}

void storage_tester::iter_end_error() {
	cut_assert_equal_int(-1, this->_container->iter_end());
	cut_assert_equal_int(0, this->_container->iter_begin());
	cut_assert_equal_int(0, this->_container->iter_end());
}

void storage_tester::truncate() {
	set_basic();
	cut_assert_equal_int(0, this->_container->truncate());
	std::string tmp;
	cut_assert_equal_int(storage::result_not_found, this->get(get_type_key(et_normal), tmp));
}

void storage_tester::count() {
	cut_assert_equal_int(this->_current_entries_nb, this->_container->count());
}

struct ind_params {
	CutTestContext* context;
	gree::flare::storage* storage;
	storage_tester::concurrent_test_type type;
	unsigned short thread_id;
	unsigned int nb_entries;
};

void* iter_next_concurrent_producer_thread(void* raw_params) {
	ind_params& params = *static_cast<ind_params*>(raw_params);
	cut_set_current_test_context(params.context);
	unsigned short nop = 0;
	for (unsigned int index = params.thread_id * params.nb_entries;
			index < (params.thread_id + 1) * params.nb_entries;
			++index) {
		std::ostringstream index_os;
		index_os << index;
		storage::entry entry = storage_tester::make_entry(index_os.str(), index_os.str());
		entry.version = 0;
		storage::result result;
		switch (params.type) {
			case storage_tester::ctt_add:
				cut_assert_equal_int(0, params.storage->set(entry, result, storage::behavior_add));
				cut_assert_equal_int(storage::result_stored, result);
				break;
			case storage_tester::ctt_replace:
				cut_assert_equal_int(0, params.storage->set(entry, result, storage::behavior_replace));
				cut_assert_equal_int(storage::result_stored, result);
				break;
			case storage_tester::ctt_remove:
				cut_assert_equal_int(0, params.storage->remove(entry, result, storage::behavior_skip_version | storage::behavior_skip_timestamp));
				cut_assert_equal_int(storage::result_deleted, result);
				break;
		}
		++nop;
	}
	cut_assert_equal_int(params.nb_entries, nop);
	return NULL;
}

void* iter_next_concurrent_consumer_thread(void* raw_params) {
	ind_params& params = *static_cast<ind_params*>(raw_params);
	cut_set_current_test_context(params.context);
	std::vector<std::string>* keys = new std::vector<std::string>();
	keys->reserve(params.nb_entries * 2);
	std::string key;
	while (storage::iteration_end != params.storage->iter_next(key)) {
		keys->push_back(key);
	}
	return keys;
}

void storage_tester::iter_next_concurrent(concurrent_test_type type) {
	static const unsigned short nb_threads = 10;
	static const unsigned int nb_entries = RUNNING_ON_VALGRIND ? 100 : 10000;
	// Check storage parameters
	cut_assert(this->_helper->_mutex_slot_size > 1,
			cut_message("For a meaningful test, please set the mutex slot size to at least 2."));
	// Params
	CutTestContext* context = cut_get_current_test_context();
	// Reset the container
	cut_assert_equal_int(0, this->_container->truncate());
	// Prepare thread parameters
	pthread_t threads[nb_threads];
	ind_params params[nb_threads];
	for (unsigned short i = 0; i < nb_threads; ++i) {
		params[i].context = context;
		params[i].storage = this->_container;
		params[i].type = ctt_add;
		params[i].thread_id = i;
		params[i].nb_entries = nb_entries;
	}
	// Concurrently write 100000 entries to the DB
	for (unsigned short i = 0; i < nb_threads; ++i) {
		pthread_create(&threads[i], NULL, iter_next_concurrent_producer_thread, &params[i]);
	}
	for (unsigned short i = 0; i < nb_threads; ++i) {
		pthread_join(threads[i], NULL);
	}
	// Check that all entries are inserted
	size_t min_count = nb_threads * nb_entries;
	cut_assert_equal_int(min_count, this->_container->count());
	// Iterate over the whole container with 1 thread, while writing with 9 others
	cut_assert_equal_int(0, this->_container->iter_begin());
	for (unsigned short i = 0; i < nb_threads; ++i) {
		if (!i) {
			pthread_create(&threads[i], NULL, iter_next_concurrent_consumer_thread, &params[i]);
		} else {
			params[i].type = type;
			if (type == ctt_add) {
				params[i].thread_id += nb_threads - 1;
			} else {
				params[i].thread_id -= 1;
			}
			pthread_create(&threads[i], NULL, iter_next_concurrent_producer_thread, &params[i]);
		}
	}
	// Join and check results
	std::vector<std::string>* keys = NULL;
	for (unsigned short i = 0; i < nb_threads; ++i) {
		if (!i) {
			pthread_join(threads[i], reinterpret_cast<void**>(&keys));
		} else {
			pthread_join(threads[i], NULL);
		}
	}
	// Stop iteration
	cut_assert_equal_int(0, this->_container->iter_end());
	// Check that the container now has the expected number of entries
	size_t max_count =
		type == ctt_add ? (nb_threads * 2 - 1) * nb_entries
		: type == ctt_replace ? min_count
		: nb_entries;
	cut_assert_equal_int(max_count, this->_container->count());
	// ... and that no less than 100000 entries were fetched during the iteration
	unsigned int total = 0;
	unsigned int duplicates = 0;
	std::vector<unsigned short> key_counts(min_count, 0);
	if (keys) {
		total += keys->size();
		for (std::vector<std::string>::const_iterator it = keys->begin();
				it != keys->end();
				++it) {
			std::istringstream key_is(*it);
			unsigned int key;
			key_is >> key;
			if (key < min_count) {
				// Check for duplicates
				if (key_counts[key]) {
					++duplicates;
				}
				++key_counts[key];
			}
		}
	}
	if (duplicates) {
		cut_notify("Notice: %d duplicate keys found during iteration", duplicates);
	}
	delete keys;
	if (type != ctt_remove) {
		cut_assert(min_count <= total, cut_message("iteration did not fetch enough keys (%d/%lu)", total, min_count));
		if (total > min_count) {
			cut_notify("Notice: iteration returns too many items (%d/%lu)", total, min_count);
		}
		// Finally, check that we have all the keys from before iter_begin()
		unsigned int expected = 0;
		for (std::vector<unsigned short>::const_iterator it = key_counts.begin();
				it != key_counts.end();
				++it) {
			cut_assert(*it > 0, cut_message("missing key detected (%ld)", it - key_counts.begin()));
		}
	}
}

storage::entry storage_tester::prepare_set_operation(entry_type type, version_type version, bool noreply, int behaviors) {
	std::string test_data = "*data*";

	storage::entry entry;
	entry.key = this->get_type_key(type);
	entry.size = test_data.size();
	entry.data = shared_byte(new uint8_t[entry.size]);
	memcpy(entry.data.get(), test_data.data(), entry.size);

	std::string stored_data;
	storage::result result = this->get(entry.key, stored_data, 0, 0, storage::behavior_skip_timestamp);
	switch (type) {
		case et_normal:
		case et_expired:
		case et_number:
		case et_zero:
			cut_assert_equal_int(storage::result_none, result);
			cut_assert_equal_string(this->get_type_value(type).c_str(), stored_data.c_str());
			break;
		default:
			cut_assert_equal_int(storage::result_not_found, result);
			break;
	}

	if (noreply) {
		entry.option |= storage::option_noreply;
	}
	
	if (behaviors & storage::behavior_skip_lock) {
		this->lock_entry(entry);
	}

	switch (version) {
		case vt_disabled:
			entry.version = 0;
			break;
		case vt_older:
			entry.version = default_version - 1;
			break;
		case vt_equal:
			entry.version = default_version;
			break;
		case vt_newer:
			entry.version = default_version + 1;
			break;
	}

	return entry;
}

void storage_tester::end_set_operation(storage::entry &e, int behaviors) {
	if (behaviors & storage::behavior_skip_lock) {
		this->unlock_entry(e);
	}
}

void storage_tester::perform_set_check(storage::entry &entry, entry_type type, version_type version, int b) {
	storage::result result;

	if (version == vt_disabled || version == vt_newer || (b & storage::behavior_skip_version)
			|| type == et_nonexistent
			|| (type == et_expired && !(b & storage::behavior_skip_timestamp))
			|| type == et_removed) {
		cut_assert_equal_int(0, this->_container->set(entry, result, b));
		cut_assert_equal_int(storage::result_stored, result);
	} else {
		cut_assert_equal_int(0, this->_container->set(entry, result, b));
		cut_assert_equal_int(storage::result_not_stored, result);
	}
}

void storage_tester::perform_append_prepend_check(storage::entry &entry, entry_type type, version_type version, int b) {
	storage::result result;
	std::string stored_data;

	if (type == et_normal
			&& (version == vt_disabled || version == vt_newer || (b & storage::behavior_skip_version))) {
		std::string expected = (b & storage::behavior_append)
			? get_type_value(type) + get_entry_value(entry)
			: get_entry_value(entry) + get_type_value(type);

		cut_assert_equal_int(0, this->_container->set(entry, result, b));
		cut_assert_equal_int(storage::result_stored, result);

		this->get(entry.key, stored_data, NULL, NULL, b & storage::behavior_skip_lock);

		cut_assert_equal_string(expected.c_str(), stored_data.c_str());
	} else {
		cut_assert_equal_int(0, this->_container->set(entry, result, b));
		cut_assert_equal_int(storage::result_not_stored, result);
	}
}

void storage_tester::perform_add_check(storage::entry &entry, entry_type type, version_type version, int b) {
	storage::result result;
	std::string stored_data;

	cut_assert_not_equal_int(0, b & storage::behavior_add);
	cut_assert_equal_int(0, this->_container->set(entry, result, b));

	if (type == et_normal
			|| (type == et_expired && (b & storage::behavior_skip_timestamp))
			|| (type == et_removed && !(b & storage::behavior_skip_timestamp))) {
		cut_assert_equal_int(storage::result_not_stored, result);
	} else {
		cut_assert_equal_int(storage::result_stored, result);
		this->get(entry.key, stored_data, NULL, NULL, b & storage::behavior_skip_lock);
		cut_assert_equal_memory(entry.data.get(), entry.size, stored_data.data(), stored_data.size());
	}
}

void storage_tester::perform_replace_check(storage::entry &entry, entry_type type, version_type version, int b) {
	storage::result result;
	std::string stored_data;

	cut_assert_not_equal_int(0, b & storage::behavior_replace);
	cut_assert_equal_int(0, this->_container->set(entry, result, b));

	if ((type == et_normal
				|| (type == et_expired && (b & storage::behavior_skip_timestamp)))
			&& (version == vt_disabled || version == vt_newer || (b & storage::behavior_skip_version))) {
		cut_assert_equal_int(storage::result_stored, result);
		this->get(entry.key, stored_data, NULL, NULL, b & storage::behavior_skip_lock);
		cut_assert_equal_memory(entry.data.get(), entry.size, stored_data.data(), stored_data.size());
	} else {
		cut_assert_equal_int(storage::result_not_stored, result);
	}
}

void storage_tester::perform_cas_check(storage::entry &entry, entry_type type, version_type version, int b) {
	storage::result result;

	cut_assert_not_equal_int(0, b & storage::behavior_cas);

	if (type == et_normal
			|| (type == et_expired && (b & storage::behavior_skip_timestamp))
			|| (type == et_removed && !(b & storage::behavior_skip_timestamp))) {
		cut_assert_equal_int(0, this->_container->set(entry, result, b));
		if (version == vt_equal) {
			cut_assert_equal_int(storage::result_stored, result);
		} else {
			cut_assert_equal_int(storage::result_exists, result);
		}
	} else {
		cut_assert_equal_int(0, this->_container->set(entry, result, b));
		cut_assert_equal_int(storage::result_not_found, result);
	}
}

void storage_tester::perform_touch_check(storage::entry &entry, entry_type type, version_type version, int b) {
	storage::result result;
	std::string stored_value = get_type_value(type);

	entry.version = 0; // Version checks are ignored by touch anyway
	entry.expire = util::realtime(60);

	cut_assert_equal_int(0, this->_container->set(entry, result, b));
	if (type == et_normal) {
		cut_assert_equal_int(storage::result_touched, result);
		cut_assert_equal_int(default_version, entry.version);
		cut_assert_equal_int(stored_value.size(), entry.size);
		cut_assert_equal_memory(stored_value.data(), stored_value.size(), entry.data.get(), entry.size);
		// check new expiration
		storage::entry get_input;
		get_input.key = entry.key;
		cut_assert_equal_int(0, this->_container->get(get_input, result, b));
		cut_assert_equal_int(storage::result_none, result);
		cut_assert_equal_int(default_version, get_input.version);
		cut_assert_equal_int(stored_value.size(), get_input.size);
		cut_assert_equal_memory(stored_value.data(), stored_value.size(), get_input.data.get(), get_input.size);
		cut_assert_equal_double(util::realtime(60), 2, get_input.expire);
	}	else {
		cut_assert_equal_int(storage::result_not_found, result);
	}
}

void storage_tester::perform_dump_check(storage::entry &entry, entry_type type, version_type version, int b) {
	storage::result result;

	entry.version = default_version;
	cut_assert_equal_int(0, this->_container->set(entry, result, b));
	
	if (type != et_nonexistent && !(b & storage::behavior_skip_version)) {
		cut_assert_equal_int(storage::result_not_stored, result);
	}
	else {
		cut_assert_equal_int(storage::result_stored, result);
	}

	entry.version = default_version + 1;

	cut_assert_equal_int(0, this->_container->set(entry, result, b));
	cut_assert_equal_int(storage::result_stored, result);

	entry.version = 0;

	cut_assert_equal_int(0, this->_container->set(entry, result, b));
	cut_assert_equal_int(storage::result_stored, result);
}

void storage_tester::set_check(entry_type type, version_type version, bool noreply, int behaviors) {
	// Prepare test data
	storage::entry entry = this->prepare_set_operation(type, version, noreply, behaviors);

	// Perform test
	if (behaviors & (storage::behavior_append | storage::behavior_prepend)) {
		perform_append_prepend_check(entry, type, version, behaviors);
	} else if (behaviors & storage::behavior_add) {
		perform_add_check(entry, type, version, behaviors);
	} else if (behaviors & storage::behavior_replace) {
		perform_replace_check(entry, type, version, behaviors);
	} else if (behaviors & storage::behavior_cas) {
		perform_cas_check(entry, type, version, behaviors);
	} else if (behaviors & storage::behavior_touch) {
		perform_touch_check(entry, type, version, behaviors);
	} else if (behaviors & storage::behavior_dump) {
		perform_dump_check(entry, type, version, behaviors);
	} else {
		perform_set_check(entry, type, version, behaviors);
	}

	// Cleaning
	this->end_set_operation(entry, behaviors);
}

void storage_tester::perform_incr_check(storage::entry &entry, bool is_incr, entry_type type, version_type version, int b) {
	storage::result result;
	
	cut_assert_equal_int(0, this->_container->incr(entry, 1, result, is_incr, b));
	if (type == et_number
			|| type == et_zero
			|| type == et_normal
			|| (type == et_expired && (b & storage::behavior_skip_timestamp))) {
		cut_assert_equal_int(storage::result_stored, result);
		uint64_t expected_value = 0;
		{
			std::istringstream stored_value_is(get_type_value(type));
			uint64_t stored_value = 0;
			stored_value_is >> expected_value;
			cut_assert_equal_int(type == et_number ? 25 : 0, expected_value);
			if (is_incr) {
				++expected_value;
			} else if (expected_value) {
				--expected_value;
			}
		}
		uint64_t stored_value = 0;
		cut_assert_equal_int(0, this->_container->get(entry, result, b));
		cut_assert_equal_int(storage::result_none, result);
		std::istringstream stored_value_is(get_entry_value(entry));
		stored_value_is >> stored_value;
		cut_assert_equal_int(expected_value, stored_value);
	} else {
		cut_assert_equal_int(storage::result_not_found, result);
	}
}

void storage_tester::incr_check(bool is_incr, entry_type type, version_type version, bool noreply, int behaviors) {
	// Prepare test data
	storage::entry entry = this->prepare_set_operation(type, version, noreply, behaviors);

	// Perform test
	perform_incr_check(entry, is_incr, type, version, behaviors);

	// Cleaning
	this->end_set_operation(entry, behaviors);
}

void storage_tester::remove_check(entry_type type, version_type version, int behaviors) {
	// Prepare test data
	storage::entry entry = this->prepare_set_operation(type, version, false, behaviors);

	// Perform test: delete the entry
	storage::result result;
	cut_assert_equal_int(0, this->_container->remove(entry, result, behaviors));
	if ((type == et_normal /* normal case */
				|| (type == et_expired && (behaviors & storage::behavior_skip_timestamp)) /* expiry check disabled */)
			&& (version != vt_older || (behaviors & storage::behavior_skip_version))) {
		cut_assert_equal_int(storage::result_deleted, result);
		// Try to get the deleted object; this should fail
		// Note: skip_timestamp is used here to ensure the item is really deleted,
		//       and not just expired
		cut_assert_equal_int(0, this->_container->get(entry, result, (behaviors & storage::behavior_skip_lock) | storage::behavior_skip_timestamp));
		cut_assert_equal_int(storage::result_not_found, result);
	} else {
		cut_assert_equal_int(storage::result_not_found, result);
	}

	// Cleaning
	this->end_set_operation(entry, behaviors);
}

void storage_tester::get_check(entry_type type, version_type version, int behaviors) {
	// Prepare test data
	storage::entry entry = this->prepare_set_operation(type, version, false, behaviors);
	entry.data = shared_byte();

	// Perform test: attempt to get the entry
	storage::result result;
	cut_assert_equal_int(0, this->_container->get(entry, result, behaviors));
	if (type == et_normal /* normal case */
			|| (type == et_expired && (behaviors & storage::behavior_skip_timestamp)) /* expiry check disabled */) {
		cut_assert_equal_int(storage::result_none, result);
		cut_assert_equal_int(default_version, entry.version);
		std::string expected = get_type_value(type);
		cut_assert_equal_memory(expected.data(), expected.size(), entry.data.get(), entry.size);
	} else {
		cut_assert_equal_int(storage::result_not_found, result);
	}

	// Cleaning
	this->end_set_operation(entry, behaviors);
}

}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
