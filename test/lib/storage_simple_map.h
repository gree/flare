/**
 *	storage_map.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef STORAGE_SIMPLE_MAP_H
#define STORAGE_SIMPLE_MAP_H

#include <storage.h>

namespace gree {
namespace flare {

/*
 *	storage simple map class
 */
class storage_simple_map : public storage {
protected:
	map<string, storage::entry>						_map;
	map<string, storage::entry>::iterator	_it;

public:
	storage_simple_map():
		storage(0, 0, NULL, NULL) {
		this->_it = this->_map.end();
	};
	virtual ~storage_simple_map() {
		this->_map.clear();
	};

	virtual int open() { this->_open = true; };
	virtual int close() { this->_open = false; };
	virtual int set(entry& e, result& r, int b = 0) {
		this->_map.insert(pair<string, storage::entry>(e.key, e));
		r = result_stored;
		return 0;
	};
	virtual int incr(entry& e, uint64_t value, result& r, bool increment, int b = 0) {
		r = result_not_stored;
		return 0;
	};
	virtual int get(entry& e, result& r, int b = 0) {
		map<string, storage::entry>::iterator it = this->_map.find(e.key);
		if (it != this->_map.end()) {
			r = result_found;
			e = (*it).second;
		} else {
			r = result_not_found;
		}
		return 0;
	};
	virtual int remove(entry& e, result& r, int b = 0) {
		this->_map.erase(e.key);
		return 0;
	};
	virtual int truncate(int b = 0) { return 0; };
	virtual int iter_begin() {
		this->_it = this->_map.begin();
		return 0;
	};
	virtual iteration iter_next(string& key) {
		if (this->_it != this->_map.end()) {
			key = (*this->_it).first;
			++this->_it;
			return iteration_continue;
		}
		return iteration_end;
	};
	virtual int iter_end() {
		this->_it = this->_map.end();
		return 0;
	};
	virtual uint32_t count() { return this->_map.size(); };
	virtual uint64_t size() { return -1; };
	virtual int get_key(string key, int limit, vector<string>& r) { return -1; };

	virtual type get_type() { return type_tch; };
	virtual bool is_capable(capability c) { return false; };

	// Helper functions for test
	void set(const string& key, const string& value, int flag) {
		storage::result result;
		storage::entry entry;
		entry.key = key;
		entry.flag = flag;
		entry.size = value.size();
		entry.data = shared_byte(new uint8_t[entry.size]);
		memcpy(entry.data.get(), value.data(), entry.size);
		this->set(entry, result);
	};
};

}	// namespace flare
}	// namespace gree

#endif // STORAGE_SIMPLE_MAP_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
