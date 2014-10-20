#ifndef	STORAGE_ENGINE_INTERFACE_H
#define	STORAGE_ENGINE_INTERFACE_H

#include <stdint.h>
#include "storage.h"

namespace gree {
namespace flare {

class storage_engine_interface {
public:
	virtual ~storage_engine_interface() {};
	virtual int open() = 0;
	virtual int close() = 0;
	virtual int set(storage::entry& e, const uint8_t* data, const int data_len) = 0;
	virtual uint8_t* get(const string& key, int& data_len) = 0;
	virtual int remove(const string& key) = 0;
	virtual int truncate() = 0;
	virtual int iter_begin() = 0;
	virtual storage::iteration iter_next(string& key) = 0;
	virtual int iter_end() = 0;
	virtual uint32_t count() = 0;
	virtual uint64_t size() = 0;

	virtual bool is_get_with_buffer_support() = 0;

	// You must check is_get_with_buffer_support() before call this method.
	virtual int get_with_buffer(const string& key, uint8_t* buffer, const int max_size) = 0;

	virtual bool is_get_volatile_support() = 0;

	// You must check is_get_with_buffer_support() before call this method.
	// Return value is pointer to volatile buffer. Unnecessary to call free().
	virtual const uint8_t* get_volatile(const string& key, int& data_len) = 0;

	virtual bool is_prefix_search_support() = 0;

	// You must check is_prefix_search_support() before call this method.
	virtual int get_key_list_with_prefix(const string& prefix, int limit, vector<string>& r) = 0;
};

}	// namespace flare
}	// namespace gree

#endif	// STORAGE_ENGINE_INTERFACE_H
