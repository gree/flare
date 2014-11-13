/**
 *	mock_storage.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef MOCK_STORAGE_H
#define MOCK_STORAGE_H

#include <string>

#include <storage.h>

namespace gree {
namespace flare {

/*
 *	storage simple map class
 */
class mock_storage : public storage {
public:
	int		iter_wait;

protected:
	map<string, storage::entry>						_map;
	map<string, storage::entry>::iterator	_it;
	bool							_is_iter;
	pthread_mutex_t		_mutex;

public:
	mock_storage(string data_dir, int mutex_slot_size, int header_cache_size);
	virtual ~mock_storage();

	virtual int open() { this->_open = true; };
	virtual int close() { this->_open = false; };
	virtual int set(entry& e, result& r, int b = 0);
	virtual int incr(entry& e, uint64_t value, result& r, bool increment, int b = 0);
	virtual int get(entry& e, result& r, int b = 0);
	virtual int remove(entry& e, result& r, int b = 0);
	virtual int truncate(int b = 0);
	virtual int iter_begin();
	virtual iteration iter_next(string& key);
	virtual int iter_end();
	virtual uint32_t count() { return this->_map.size(); };
	virtual uint64_t size() { return -1; };
	virtual int get_key(string key, int limit, vector<string>& r) { return -1; };

	virtual type get_type() { return type_tch; };
	virtual bool is_capable(capability c) { return false; };

	// Helper functions for test
	void set_helper(const string& key, const string& value, int flag = 0, int version = 0);
	void get_helper(const string& key, entry& e);

protected:
	virtual int _get_header(string key, entry& e) { return -1; };
};

}	// namespace flare
}	// namespace gree

#endif // MOCK_STORAGE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
