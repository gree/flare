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
 *	zookeeper_coordinator.h
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#ifndef	__ZOOKEEPER_COORDINATOR_H__
#define	__ZOOKEEPER_COORDINATOR_H__

#include <zookeeper/zookeeper.h>
#include <boost/tuple/tuple.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/regex.hpp>
#include <vector>
#include <deque>

#include "coordinator.h"
#include "zookeeper_lock.h"

using namespace std;

namespace gree {
namespace flare {

class zookeeper_coordinator : public coordinator
{
public:
	static const int		default_retry_count = 10;
	typedef boost::tuple<string,string,int> authority_type;

protected:
	class zk_operation : public operation
	{
		zookeeper_lock		_zklock;
		string						_message;
	public:
		zk_operation(zookeeper_coordinator *coord, const string& connstring, const string& path, const string& message = ""):
				operation(coord),
				_zklock(connstring, path),
				_message(message) {
		}
		~zk_operation() {}
	public:
		int lock() { this->_zklock.set_message(this->_message); return this->_zklock.lock(); }
		int unlock() { return this->_zklock.unlock(); }
		int wait_for_ownership() { return this->_zklock.wait_for_ownership(); }
		void set_message(const string& message) { this->_message = message; }
		string get_message() { return this->_message; }
		string get_lock_id() { return this->_zklock.get_id(); }
		string get_nickname() { return this->_zklock.get_nickname(); }
	};

	struct ext_uri {
		string scheme;
		vector<authority_type> authorities;
		string path;
		string query;
		string fragment;

		/**
		 *  scheme://[user@][host][:port]/[path][?query][#fragment]
		 */
		ext_uri(string s) {
			static const char * auth_pattern = 
				"(?:([^:/@]*)@)?([^:@/]*)(?::(\\d+))?"; // [userinfo@]host[:port]
			static const char * pattern = "\\A"
				"([^:]+)://" // scheme(1)
				"([^,/]*)?(?:,([^,/]*))?(?:,([^,/]*))?(?:,([^,/]*))?(?:,([^,/]*))?" // authority(2-6)
				"(/[^\\?]*)(?:\\?([^#]*))?(?:#(.*))?" // path?query#fragment(7-9)
				"\\z";

			vector<string> authstrings;
			static const boost::regex e(pattern);
			boost::smatch match;
			boost::regex_match(s, match, e);
			this->scheme    = match[1].str();
			authstrings.push_back(match[2].str());
			for (int i = 3; i < 7; i++) {
				if (match[i].matched) {
					authstrings.push_back(match[i].str());
				}
			}
			for(vector<string>::iterator it = authstrings.begin(); it != authstrings.end(); it++) {
				static const boost::regex auth_e(auth_pattern);
				boost::smatch auth_match;
				boost::regex_match(*it, auth_match, auth_e);
				string user      = auth_match[1].str();
				string host      = auth_match[2].str();
				int port         = 0;
				try {
					port           = boost::lexical_cast<int>(auth_match[3].str());
				} catch (boost::bad_lexical_cast& e) {}
				authorities.push_back(boost::make_tuple(user, host, port));
			}

			this->path      = match[7].str();
			this->query     = match[8].str();
			this->fragment  = match[9].str();
		}
	};

private:
	ext_uri						_uri;
	string						_myname;
	string						_connstring;
	zhandle_t*				_zhandle;
	clientid_t				_client_id;
	boost::function<void (void)>	_update_handler;
	pthread_mutex_t		_mutex_sync_nodemap;
	pthread_cond_t		_cond_sync_nodemap;
	bool							_sync_nodemap;
	int								_retry;
	bool							_is_initialized;
	deque<shared_operation> operation_pool;
	pthread_mutex_t		_mutex_operation_pool;

public:
	zookeeper_coordinator(const string& coordinator_uri, const string& myname);
	virtual ~zookeeper_coordinator();

	virtual int begin_operation(shared_operation& operation, const string& message);
	virtual int end_operation(shared_operation& operation);
	virtual int store_state(const string& flare_xml);
	virtual int restore_state(string& flare_xml);

	int setup();
	bool is_initialized() { return this->_is_initialized; }
	string get_scheme() { return this->_uri.scheme; }
	vector<boost::tuple<string,string,int> > get_authorities() { return this->_uri.authorities; }
	string get_user()   { return this->_uri.authorities.front().get<0>(); }
	string get_host()   { return this->_uri.authorities.front().get<1>(); }
	int get_port()      { return this->_uri.authorities.front().get<2>(); }
	string get_path()   { return this->_uri.path; }
	void set_update_handler(boost::function<void (void)> fn) { this->_update_handler = fn; }
	int get_meta_variables(map<string,string>& variables);
	zhandle_t* get_zhandle();

protected:
	void _close_zookeeper();
	boost::shared_ptr<zk_operation> _new_operation();
	boost::shared_ptr<zk_operation> _take_operation();
	void _put_operation(boost::shared_ptr<zk_operation> zkop);
	virtual void _handle_global_watch_event(int type, int state, const string& path);
	virtual void _handle_nodemap_watch_event(int type, int state, const string& path);
	virtual void _handle_sync_completion_event(int rc, const string& value);

private:
	static void _nodemap_watcher_fn(zhandle_t* zh, int type, int state,
																	const char* path, void* watcherCtx);
	static void _global_watcher_fn(zhandle_t* zh, int type, int state,
																 const char* path, void* watcherCtx);
	static void _sync_completion_fn(int rc, const char *value, const void *data);
};

}	// namespace flare
}	// namespace gree

#endif	// __ZOOKEEPER_COORDINATOR_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
