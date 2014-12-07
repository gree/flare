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
 *	file_coordinator.cc
 *
 *	implementation of gree::flare::file_coordinator
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */

#include <iostream>
#include <sstream>
#include <boost/format.hpp>

#include "util.h"
#include "logger.h"
#include "zookeeper_coordinator.h"

namespace gree {
namespace flare {

#define ZNODENAME_INDEX_LOCK		"/index/lock"
#define ZNODENAME_INDEX_NODEMAP	"/index/nodemap"
#define ZNODENAME_INDEX_META		"/index/meta"

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for cluster
 */
zookeeper_coordinator::zookeeper_coordinator(const string& coordinator_uri, const string& myname)
	: _uri(coordinator_uri),
		_myname(myname),
		_zhandle(NULL),
		_update_handler(NULL),
		_sync_nodemap(false),
		_retry(default_retry_count) {

	pthread_mutex_init(&(this->_mutex_sync_nodemap), NULL);
	pthread_cond_init(&(this->_cond_sync_nodemap), NULL);
	pthread_mutex_init(&(this->_mutex_operation_pool), NULL);

	/* check the scheme part of identifier */
	if (this->get_scheme() != "zookeeper") {
		log_warning("invalid scheme [%s]", this->get_scheme().c_str());
	}

	/* construct a connection string */
	ostringstream connstring_oss;
	for (vector<boost::tuple<string,string,int> >::iterator it = this->_uri.authorities.begin();
			 it != this->_uri.authorities.end(); it++) {
		string host = it->get<1>();
		int port = it->get<2>();
		if (it != this->_uri.authorities.begin()) {
			connstring_oss << ",";
		}
		connstring_oss << host << ":" << port;
	}
	connstring_oss << this->_uri.path;
	this->_connstring = connstring_oss.str();
	
	log_info("zookeeper connstring [%s]", this->_connstring.c_str());

	/* initialize zookeeper */
	this->_client_id.client_id = 0;
	this->_zhandle = zookeeper_init(this->_connstring.c_str(), zookeeper_coordinator::_global_watcher_fn,
																	10000, 0, reinterpret_cast<void *>(this), 0);

	this->_put_operation(this->_new_operation());
}

/**
 *	dtor for cluster
 */
zookeeper_coordinator::~zookeeper_coordinator() {
	this->_close_zookeeper();
	pthread_mutex_destroy(&(this->_mutex_operation_pool));
	pthread_mutex_destroy(&(this->_mutex_sync_nodemap));
	pthread_cond_destroy(&(this->_cond_sync_nodemap));
}
// }}}

// {{{ public methods
int zookeeper_coordinator::begin_operation(shared_operation& operation, const string& message) {
	operation.reset();
	boost::shared_ptr<zk_operation> zkop = this->_take_operation();

	try {
		if (!zkop) {
			log_err("no lock operation", 0);
			throw -1;
		}
		zkop->set_message(message);
		if (zkop->lock() < 0) {
			throw -1;
		}
		if (zkop->wait_for_ownership()) {
			throw -1;
		}

		// flush leader channel
		pthread_mutex_lock(&(this->_mutex_sync_nodemap));
		this->_sync_nodemap = false;
		pthread_mutex_unlock(&(this->_mutex_sync_nodemap));
		int ret = zoo_async(this->get_zhandle(), ZNODENAME_INDEX_NODEMAP, 
												zookeeper_coordinator::_sync_completion_fn, this);
		if (ret != ZOK) {
			log_warning("failed to flush leader channel", 0);
			if (zkop->unlock() < 0) {
				log_err("failed to unlock", 0);
			}
			throw -1;
		}
	} catch (int e) {
		this->_put_operation(this->_new_operation());
		return e;
	}

	pthread_mutex_lock(&(this->_mutex_sync_nodemap));
	while (this->_sync_nodemap == false) {
		pthread_cond_wait(&(this->_cond_sync_nodemap), &(this->_mutex_sync_nodemap));
	}
	pthread_mutex_unlock(&(this->_mutex_sync_nodemap));

	log_notice("begin operation: %s (%s)", zkop->get_message().c_str(), zkop->get_nickname().c_str());
	operation = zkop;
	return 0;
}

int zookeeper_coordinator::end_operation(shared_operation& operation) {
	boost::shared_ptr<zk_operation> zkop = boost::dynamic_pointer_cast<zk_operation>(operation);
	log_notice("end operation: %s (%s)", zkop->get_message().c_str(), zkop->get_nickname().c_str());
	operation.reset();
	if (zkop->unlock() < 0) {
		log_warning("failed to unlock: %s", zkop->get_message().c_str());
		return -1;
	}
	this->_put_operation(zkop);
	log_notice("end operation: exit - %s (%s)", zkop->get_message().c_str(), zkop->get_nickname().c_str());
	return 0;
}

int zookeeper_coordinator::store_state(const string& flare_xml) {
	int ret = zoo_set(this->get_zhandle(), ZNODENAME_INDEX_NODEMAP, flare_xml.c_str(), flare_xml.size(), -1);
	if (ret != ZOK) {
		log_warning("failed to set state %s (%s)", ZNODENAME_INDEX_NODEMAP, zerror(ret));
	}
	return ret;
}

int zookeeper_coordinator::restore_state(string& flare_xml) {
	if (this->get_zhandle() == NULL) {
		return -1;
	}

	int ret = ZCONNECTIONLOSS;
	struct Stat stat;
	int bufsize = 8192;
	char* buf = new char[bufsize+sizeof('\0')];

	ret = zoo_get(this->get_zhandle(), ZNODENAME_INDEX_NODEMAP, 0, buf, &bufsize, &stat);
	if (ret == ZOK) {
		if (bufsize == -1) {
			log_err("empty state", 0);
			delete[] buf;
			return -1;
		} else if (stat.dataLength != bufsize) {
			log_info("stat.dataLength(%d) != bufsize(%d)", stat.dataLength, bufsize);
			delete[] buf;
			buf = NULL;
			bufsize = stat.dataLength;
			buf = new char[bufsize+sizeof('\0')];
			ret = zoo_get(this->get_zhandle(), ZNODENAME_INDEX_NODEMAP, 0, buf, &bufsize, &stat);
		}
	}
	if (ret == ZOK) {
		flare_xml = string(buf, bufsize);
	} else {
		log_warning("failed to get state %s (%s)", ZNODENAME_INDEX_NODEMAP, zerror(ret));
	}

	delete[] buf;
	return ret;
}

int zookeeper_coordinator::get_meta_variables(map<string,string>& variables) {
	vector<string> nodevector;
	struct String_vector children;
	int count = 0;

	children.data = NULL;
	children.count = 0;

	int ret = ZCONNECTIONLOSS;
	while (ret == ZCONNECTIONLOSS && count < this->_retry) {
		ret = zoo_get_children(this->get_zhandle(), ZNODENAME_INDEX_META, 0, &children);
		if (ret == ZCONNECTIONLOSS) {
			log_info("connection loss to the server (%s)", zerror(ret));
			sleep(1);
			count++;
		}
	}

	if (children.data) {
		for (int32_t i = 0; i < children.count; i++) {
			nodevector.push_back(string(children.data[i]));
			free(children.data[i]);
		}
		free(children.data);
		children.data = NULL;
	}
	
	for (vector<string>::iterator it = nodevector.begin(); it != nodevector.end(); it++) {
		string path = ZNODENAME_INDEX_META;
		path += "/"+(*it);
		char buf[512];
		struct Stat stat;
		int bufsize = sizeof(buf);
		ret = zoo_get(this->_zhandle, path.c_str(), 0, buf, &bufsize, &stat);
		if (ret == ZOK) {
			variables[*it] = string(buf, bufsize);
		}
	}
	return ret;
}

zhandle_t* zookeeper_coordinator::get_zhandle() {
	return this->_zhandle;
}

int zookeeper_coordinator::setup() {
	if (this->_zhandle == NULL) {
		log_err("zookeeper not initialized [%s].", this->_connstring.c_str());
		return -1;
	}

	int ret = ZCONNECTIONLOSS;
	int count = 0;
	while (ret == ZCONNECTIONLOSS && count < this->_retry) {
		ret = zoo_create(this->_zhandle, ("/index/servers/"+this->_myname).c_str(),
										 "", 0, &ZOO_OPEN_ACL_UNSAFE, ZOO_EPHEMERAL, NULL, 0);
		if (ret == ZCONNECTIONLOSS) {
			log_debug("connection loss to the server (%s)", zerror(ret));
			sleep(1);
			count++;
		}
	}
	if (ret != ZOK) {
		log_err("failed to create my ephemeral node %s (%s)", ("/index/servers/"+this->_myname).c_str(), zerror(ret));
		return -1;
	}
	
	struct Stat stat;
	ret = ZCONNECTIONLOSS;
	count = 0;
	while (ret == ZCONNECTIONLOSS && count < this->_retry) {
		ret = zoo_wexists(this->_zhandle, ZNODENAME_INDEX_NODEMAP,
											zookeeper_coordinator::_nodemap_watcher_fn, reinterpret_cast<void *>(this),
											&stat);
		if (ret == ZCONNECTIONLOSS) {
			log_debug("connection loss to the server (%s)", zerror(ret));
			sleep(1);
			count++;
		}
	}
	if (ret != ZOK) {
		log_err("failed to watch nodemap %s (%s)", ZNODENAME_INDEX_NODEMAP, zerror(ret));
		return -1;
	}
	
	this->_is_initialized = true;
	return 0;
}
// }}}

// {{{ protected methods
void zookeeper_coordinator::_close_zookeeper() {
	if (this->_zhandle != NULL) {
		zookeeper_close(this->_zhandle);
		this->_zhandle = NULL;
	}
}

boost::shared_ptr<zookeeper_coordinator::zk_operation> zookeeper_coordinator::_take_operation() {
	boost::shared_ptr<zk_operation> zkop;
	pthread_mutex_lock(&(this->_mutex_operation_pool));
	if (this->operation_pool.size() > 0) {
		zkop = boost::dynamic_pointer_cast<zk_operation>(this->operation_pool.front());
		this->operation_pool.pop_front();
	} else {
		zkop = this->_new_operation();
	}
	pthread_mutex_unlock(&(this->_mutex_operation_pool));
	return zkop;
}

boost::shared_ptr<zookeeper_coordinator::zk_operation> zookeeper_coordinator::_new_operation() {
	return (boost::shared_ptr<zk_operation>(new zookeeper_coordinator::zk_operation(this, this->_connstring, string(ZNODENAME_INDEX_LOCK))));
}

void zookeeper_coordinator::_put_operation(boost::shared_ptr<zk_operation> zkop) {
	pthread_mutex_lock(&(this->_mutex_operation_pool));
	this->operation_pool.push_back(zkop);
	pthread_mutex_unlock(&(this->_mutex_operation_pool));
}

void zookeeper_coordinator::_handle_global_watch_event(int type, int state, const string& path) {
	// ignore EventType.None(-1). see org/apache/zookeeper/Watcher.java
	if (type == -1) {
		return;
	}
	if (this->_zhandle == NULL) {
		log_warning("zookeeper session not established", 0);
		return;
	}

	log_notice("event (type=%d, state=%d, path=%s)", type, state, path.c_str());

	if (type == ZOO_SESSION_EVENT) {
		if (state == ZOO_CONNECTED_STATE) {
			const clientid_t *id = zoo_client_id(this->_zhandle);
			if (this->_client_id.client_id != id->client_id) {
				if (this->_client_id.client_id == 0) {
					log_info("session established. %lld", (long long int) id->client_id);
				} else {
					log_warning("session reestablished. %lld -> %lld",
											(long long int) this->_client_id.client_id,
											(long long int) id->client_id);
				}
				this->_client_id = *id;
			}
		} else if (state == ZOO_AUTH_FAILED_STATE) {
			log_warning("authentication failure", 0);
			_close_zookeeper();
		} else if (state == ZOO_EXPIRED_SESSION_STATE) {
			log_warning("zookeeper session expired", 0);
			_close_zookeeper();
		}
	}
}

void zookeeper_coordinator::_handle_nodemap_watch_event(int type, int state, const string& path) {
	// ignore EventType.None(-1). see org/apache/zookeeper/Watcher.java
	if (type == -1) {
		return;
	}
	if (this->_zhandle == NULL) {
		log_warning("zookeeper session not established", 0);
		return;
	}

	if (type == ZOO_CHANGED_EVENT) {
		if (this->_update_handler != NULL) {
			this->_update_handler();
		}
		struct Stat stat;
		int ret = zoo_wexists(this->_zhandle, ZNODENAME_INDEX_NODEMAP,
													zookeeper_coordinator::_nodemap_watcher_fn, reinterpret_cast<void *>(this),
													&stat);
		if (ret != ZOK) {
			log_err("failed to watch nodemap %s (%s)", ZNODENAME_INDEX_NODEMAP, zerror(ret));
		}
	} else {
		log_warning("unknown event (type=%d, state=%d, path=%s)", type, state, path.c_str());
	}
}

void zookeeper_coordinator::_handle_sync_completion_event(int rc, const string& value) {
	log_info("completed", 0);
	pthread_mutex_lock(&this->_mutex_sync_nodemap);
	this->_sync_nodemap = true;
	pthread_cond_broadcast(&this->_cond_sync_nodemap);
	pthread_mutex_unlock(&this->_mutex_sync_nodemap);
}
// }}}

// {{{ private methods
void zookeeper_coordinator::_global_watcher_fn(zhandle_t* zh, int type, int state,
																						const char* path, void* watcherCtx) {
	zookeeper_coordinator* coordinator = reinterpret_cast<zookeeper_coordinator *>(watcherCtx);
	if (coordinator != NULL) {
		coordinator->_handle_global_watch_event(type, state, string(path));
	}
}

void zookeeper_coordinator::_nodemap_watcher_fn(zhandle_t* zh, int type, int state,
																								const char* path, void* watcherCtx) {
	zookeeper_coordinator* coordinator = reinterpret_cast<zookeeper_coordinator *>(watcherCtx);
	if (coordinator != NULL) {
		coordinator->_handle_nodemap_watch_event(type, state, string(path));
	}
}

void zookeeper_coordinator::_sync_completion_fn(int rc, const char *value, const void *data) {
	zookeeper_coordinator* coordinator = (zookeeper_coordinator *)(data);
	if (coordinator != NULL) {
		coordinator->_handle_sync_completion_event(rc, string(value));
	}
}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
