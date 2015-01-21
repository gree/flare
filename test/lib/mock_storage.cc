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
 *	mock_storage.cc
 *
 *	implementation of gree::flare::mock_storage class
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#include "mock_storage.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
mock_storage::mock_storage(string data_dir, int mutex_slot_size, int header_cache_size):
	storage(data_dir, mutex_slot_size, header_cache_size),
	iter_wait(-1),
	_is_iter(false) {
	this->_it = this->_map.end();
	pthread_mutex_init(&this->_mutex, NULL);
}

mock_storage::~mock_storage() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int mock_storage::set(entry& e, result& r, int b) {
	pthread_mutex_lock(&this->_mutex);
	if (this->_map.count(e.key) > 0) {
		if (this->_map[e.key].version < e.version) {
			this->_map[e.key] = e;
		}
	} else {
		this->_map[e.key] = e;
	}
	pthread_mutex_unlock(&this->_mutex);
	r = result_stored;
	return 0;
}

int mock_storage::incr(entry& e, uint64_t value, result& r, bool increment, int b) {
	r = result_not_stored;
	return 0;
}

int mock_storage::get(entry& e, result& r, int b) {
	pthread_mutex_lock(&this->_mutex);
	map<string, storage::entry>::iterator it = this->_map.find(e.key);
	if (it != this->_map.end()) {
		r = result_found;
		e = (*it).second;
	} else {
		r = result_not_found;
	}
	pthread_mutex_unlock(&this->_mutex);
	return 0;
}

int mock_storage::remove(entry& e, result& r, int b) {
	pthread_mutex_lock(&this->_mutex);
	this->_map.erase(e.key);
	pthread_mutex_unlock(&this->_mutex);
	return 0;
}

int mock_storage::truncate(int b) {
	pthread_mutex_lock(&this->_mutex);
	this->_map.clear();
	pthread_mutex_unlock(&this->_mutex);
	return 0;
}

int mock_storage::iter_begin() {
	if (!this->_is_iter) {
		this->_is_iter = true;
		pthread_mutex_lock(&this->_mutex);
		this->_it = this->_map.begin();
		pthread_mutex_unlock(&this->_mutex);
		return 0;
	} else {
		return -1;
	}
}

storage::iteration mock_storage::iter_next(string& key) {
	if (!this->_is_iter) {
		return iteration_error;
	}
	if (this->iter_wait > 0) {
		usleep(iter_wait);
	}
	pthread_mutex_lock(&this->_mutex);
	if (this->_it != this->_map.end()) {
		key = (*this->_it).first;
		++this->_it;
		pthread_mutex_unlock(&this->_mutex);
		return iteration_continue;
	}
	pthread_mutex_unlock(&this->_mutex);
	return iteration_end;
}

int mock_storage::iter_end() {
	if (this->_is_iter) {
		this->_is_iter = false;
		pthread_mutex_lock(&this->_mutex);
		this->_it = this->_map.end();
		pthread_mutex_unlock(&this->_mutex);
		return 0;
	} else {
		return -1;
	}
}

void mock_storage::set_helper(const string& key, const string& value, int flag, int version) {
	storage::result result;
	storage::entry entry;
	entry.key = key;
	entry.flag = flag;
	entry.version = version;
	entry.size = value.size();
	entry.data = shared_byte(new uint8_t[entry.size]);
	memcpy(entry.data.get(), value.data(), entry.size);
	this->set(entry, result);
}

void mock_storage::get_helper(const string& key, entry& e) {
	e = this->_map[key];
}
// }}}


// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
