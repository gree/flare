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
 *	zookeeper_lock.h
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#ifndef	__ZOOKEEPER_LOCK_H__
#define	__ZOOKEEPER_LOCK_H__

#include "config.h"
#include <zookeeper/zookeeper.h>
#include <string>

using namespace std;

namespace gree {
namespace flare {

class zookeeper_lock
{
public:
	static const int		default_retry_count = 10;
	enum							session_state {
		session_state_inactive = 0,
		session_state_active,
		session_state_finished,
	};

private:
	zhandle_t*					_zh;
	const string				_path;
	struct ACL_vector*	_acl;
	string							_id;
	pthread_mutex_t			_mutex_lock;
	volatile bool				_is_owner;
	string							_owner_id;
	struct timespec			_wait_ts;
	pthread_mutex_t			_mutex_ownership;
	pthread_cond_t			_cond_ownership;
	string							_prefix;
	string							_message;
	session_state				_session_state;
	pthread_mutex_t			_mutex_session_state;
	pthread_cond_t			_cond_session_state;

public:
	zookeeper_lock(const string& connstring, const string& path, struct ACL_vector* acl = &ZOO_OPEN_ACL_UNSAFE);
	virtual ~zookeeper_lock();

public:
	int lock(bool again = false);
	int unlock();
	int wait_for_ownership();
	string get_nickname();
	string get_path() { return this->_path; }
	bool is_owner() {
		if (this->_id.empty() || this->_owner_id.empty()) {
			return false;
		}
    return (this->_id == this->_owner_id);
	}
	string get_id() { return this->_id; }
	string get_owner_id() { return this->_owner_id; }
	void set_message(const string& message) { this->_message = message; }
	string get_message() { return this->_message; }
	zhandle_t* get_zhandle() { return this->_zh; }

protected:
	virtual int _invoke_locked();
	virtual int _invoke_unlocked();
	virtual void _handle_lock_watch_event(int type, int state, const string& path);
	virtual void _handle_global_watch_event(int type, int state, const string& path);
	
private:
	int _lock_internal(bool again, int& zerr);
	int _unlock_internal(int& zerr);
	int _lookup_node(vector<string>& nodevector, const string& prefix, string& child);
	int _lock_operation(bool again, int& zerr);
	int _retry_getchildren(const string path, vector<string>& nodevector, int retry, int& zerr);
	int _retry_wexists(const string path, watcher_fn watcher, void* ctx,
										 struct Stat *stat, struct timespec *ts, int retry, int& zerr);
	int _child_floor(vector<string>& nodevector, const string& node, string& lessthanme);
	int _reset_lock();
	int _assure_session_connected();
	static void _lock_watcher_fn(zhandle_t* zh, int type, int state,
															 const char* path, void *watcherCtx);
	static void _global_watcher_fn(zhandle_t* zh, int type, int state,
																 const char* path, void* watcherCtx);
};

}	// namespace flare
}	// namespace gree

#endif	// __ZOOKEEPER_LOCK_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
