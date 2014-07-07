/**
 *	zookeeper_lock.cc
 *
 *	implementation of gree::flare::zookeeper_lock
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */

#include <boost/algorithm/string.hpp>
#include <boost/format.hpp>
#include <uuid/uuid.h>

#include "util.h"
#include "zookeeper_lock.h"

#define ZOOKEEPER_LOCK_USE_TIMEDWAIT
#define ZOOKEEPER_LOCK_TIMEDWAIT_TIMEOUT 1

namespace gree {
namespace flare {

static string nickname(const string& id) {
	vector<string> pathnodes;
	algorithm::split(pathnodes, id, is_any_of("/"));
	if (pathnodes.size() > 0) {
		string name = pathnodes.back();
		try {
			return name.substr(0, 8)+name.substr(41);
		} catch (out_of_range& e) {
			return name;
		}
	} else {
		return id;
	}
}

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for zookeeper_lock
 */
zookeeper_lock::zookeeper_lock(const string& connstring, const string& path, struct ACL_vector *acl)
	: _zh(NULL),
		_path(path),
		_acl(acl),
		_is_owner(false) {
	this->_wait_ts.tv_sec = 0;
	this->_wait_ts.tv_nsec = (.5)*1000000;
	pthread_mutex_init(&(this->_mutex_lock), NULL);
	pthread_mutex_init(&(this->_mutex_ownership), NULL);
	pthread_cond_init(&(this->_cond_ownership), NULL);
	this->_session_state = session_state_inactive;
	pthread_mutex_init(&(this->_mutex_session_state), NULL);
	pthread_cond_init(&(this->_cond_session_state), NULL);
	this->_zh = zookeeper_init(connstring.c_str(), zookeeper_lock::_global_watcher_fn,
														 10000, 0, reinterpret_cast<void *>(this), 0);
	this->_reset_lock();
}

/**
 *	dtor for zookeeper_lock
 */
zookeeper_lock::~zookeeper_lock() {
	if (!this->_id.empty()) {
	  this->unlock();
  }

	log_info("closing [%s] - %s", this->_path.c_str(), this->_message.c_str());
	if (this->_zh) {
		zookeeper_close(this->_zh);
	}

	// release
	pthread_cond_destroy(&(this->_cond_session_state));
	pthread_mutex_destroy(&(this->_mutex_session_state));
	pthread_cond_destroy(&(this->_cond_ownership));
	pthread_mutex_destroy(&(this->_mutex_ownership));
	pthread_mutex_destroy(&(this->_mutex_lock));

	log_info("destroyed [%s] - %s", this->_path.c_str(), this->_message.c_str());
}
// }}}

// {{{ public methods
/*
 * lock - request for lock
 */
int zookeeper_lock::lock(bool again) {
	const string msg = this->get_message();
	const string nick = this->get_nickname();
	int ret = 0, zerr;
	log_notice("enter [%s] - %s", nick.c_str(), msg.c_str());

	if (this->_assure_session_connected() < 0) {
		return -1;
	}

	pthread_mutex_lock(&(this->_mutex_lock));
	if ((ret = this->_lock_internal(again, zerr)) < 0) {
		if (!again) {
			log_warning("failed to request lock [%s] (%s) - %s", this->_path.c_str(), zerror(zerr), msg.c_str());
		}
	} else {
		if (this->_is_owner) {
			log_info("lock acquired [%s] - %s", nick.c_str(), msg.c_str());
		} else {
			log_info("lock requested [%s] - %s", nick.c_str(), msg.c_str());
		}
	}
	pthread_mutex_unlock(&(this->_mutex_lock));

	log_notice("exit [%s] - %s", nick.c_str(), msg.c_str());
	return ret;
}

/*
 * unlock - just removes the node for locking
 */
int zookeeper_lock::unlock() {
	const string msg = this->get_message();
	const string nick = this->get_nickname();
	int ret, zerr;
	log_notice("enter [%s] - %s", nick.c_str(), msg.c_str());

	if (this->_assure_session_connected() < 0) {
		return -1;
	}

	pthread_mutex_lock(&(this->_mutex_lock));
	do {
		if ((ret = this->_unlock_internal(zerr)) < 0) {
			log_warning("retrying unlock operation [%s] (%s) - %s", nick.c_str(), zerror(zerr), msg.c_str());
		}
	} while (ret < 0);
	pthread_mutex_unlock(&(this->_mutex_lock));

	log_notice("exit [%s] - %s", nick.c_str(), msg.c_str());
	return ret;
}

/*
 * wait_for_ownership - blocking
 */
int zookeeper_lock::wait_for_ownership() {
	const string msg = this->get_message();
	const string nick = this->get_nickname();
	int ret = 0;
	log_notice("enter [%s] - %s", nick.c_str(), msg.c_str());

	if (this->_assure_session_connected() < 0) {
		return -1;
	}

	pthread_mutex_lock(&this->_mutex_ownership);
	for (int count = 0; !this->_is_owner; count++) {
		if (count == 0) {
			log_info("waiting [%s] - %s", nick.c_str(), msg.c_str());
		}
#ifdef ZOOKEEPER_LOCK_USE_TIMEDWAIT
		int zerr;
		const int timeout_sec = ZOOKEEPER_LOCK_TIMEDWAIT_TIMEOUT;
		struct timespec timeout;
		timeout.tv_sec = time(NULL)+timeout_sec+timeout_sec*count;
		timeout.tv_nsec = 0;
		int r = pthread_cond_timedwait(&this->_cond_ownership, &this->_mutex_ownership, &timeout);
		if (r == ETIMEDOUT) {
			log_notice("timed out [%s] (%d iterations) - %s", nick.c_str(), count, msg.c_str());
			if (!this->_is_owner) {
				pthread_mutex_unlock(&this->_mutex_ownership);
				ret = this->_lock_internal(false, zerr);
				pthread_mutex_lock(&this->_mutex_ownership);
			}
		}
#else
		pthread_cond_wait(&this->_cond_ownership, &this->_mutex_ownership);
#endif
		if (this->_is_owner && count > 0) {
			log_info("wakeup [%s] after %d retries - %s", nick.c_str(), count, msg.c_str());
		}
	}
	pthread_mutex_unlock(&this->_mutex_ownership);
	log_notice("exit [%s] - %s", nick.c_str(), msg.c_str());
	return ret;
}

string zookeeper_lock::get_nickname() {
	return nickname(this->_id);
}
// }}}

// {{{ protected methods
int zookeeper_lock::_invoke_locked() {
	return 0;
}

int zookeeper_lock::_invoke_unlocked() {
	return 0;
}

/*
 * Predecessor (previous lock node) watcher
 * 
 * This method is called by zookeeper thread.
 */
void zookeeper_lock::_handle_lock_watch_event(int type, int state, const string& path) {
	if (state == ZOO_EXPIRED_SESSION_STATE) {
		log_err("zookeeper session expired <%s> - %s", nickname(path).c_str(), this->_message.c_str());
		return;
	}

	if (type == ZOO_SESSION_EVENT) {
		log_info("SESSION_EVENT <%s> - %s", nickname(path).c_str(), this->_message.c_str());
	} else if (type == ZOO_DELETED_EVENT) {
		log_info("DELETED <%s> - %s", nickname(path).c_str(), this->_message.c_str());
		log_debug("lock again [%s] - %s", nickname(this->_id).c_str(), this->_message.c_str());
		this->lock(true);
	} else if (type == ZOO_CHANGED_EVENT) {
		log_info("CHANGED <%s> - %s", nickname(path).c_str(), this->_message.c_str());
	} else {
		log_warning("unknown event (type=%d, state=%d, path=%s) - %s", type, state, nickname(path).c_str(), this->_message.c_str());
	}
}

/*
 * Global watcher
 * 
 * This method is called by zookeeper thread.
 */
void zookeeper_lock::_handle_global_watch_event(int type, int state, const string& path) {
	if (type == ZOO_SESSION_EVENT) {
		pthread_mutex_lock(&this->_mutex_session_state);
		if (state == ZOO_CONNECTED_STATE) {
			log_notice("connected to zookeeper server - %s", this->_message.c_str());
			this->_session_state = session_state_active;
		} else if (state == ZOO_EXPIRED_SESSION_STATE) {
			log_notice("zookeeper session expired - %s", this->_message.c_str());
			this->_session_state = session_state_finished;
		} else if (state == ZOO_CONNECTING_STATE) {
			log_notice("connecting to zookeeper server - %s", this->_message.c_str());
			this->_session_state = session_state_inactive;
		} else {
			log_notice("zookeeper session changed - %s", this->_message.c_str());
			this->_session_state = session_state_inactive;
		}
		pthread_cond_broadcast(&this->_cond_session_state);
		pthread_mutex_unlock(&this->_mutex_session_state);
	}
}
// }}}

// {{{ private methods
int zookeeper_lock::_lookup_node(vector<string>& nodevector, const string& prefix, string& child) {
	for (vector<string>::iterator it = nodevector.begin(); it != nodevector.end(); it++) {
		if (it->substr(0, prefix.size()) == prefix) {
			child = *it;
			return 0;
		}
	}
	return -1;
}

/*
 * wrapping zoo_get_children()
 */
int zookeeper_lock::_retry_getchildren(const string path, vector<string>& nodevector, int retry, int& zerr) {
	struct String_vector children;
	int count = 0;

	children.data = NULL;
	children.count = 0;

	zerr = ZCONNECTIONLOSS;
	while (zerr == ZCONNECTIONLOSS && count < retry) {
		zerr = zoo_get_children(this->_zh, path.c_str(), 0, &children);
		if (zerr == ZCONNECTIONLOSS) {
			log_info("connection loss to the server (%s) - %s", zerror(zerr), this->_message.c_str());
			nanosleep(&this->_wait_ts, 0);
			count++;
		}
	}
	if (zerr != ZOK) {
		return -1;
	}

	if (children.data) {
		nodevector.clear();
		for (int32_t i = 0; i < children.count; i++) {
			nodevector.push_back(string(children.data[i]));
			free(children.data[i]);
		}
		free(children.data);
		children.data = NULL;
	}
	return 0;
}

struct less_than_with_suffix {
	bool operator()(const string& left, const string& right) const {
		string::size_type li = left.find_last_of('-');
		string::size_type ri = right.find_last_of('-');
#ifdef DEBUG
		assert(li != string::npos && ri != string::npos);
#endif
		return left.substr(li+1) < right.substr(ri+1);
	}
};

/*
 * retry zoo_wexists
 */
int zookeeper_lock::_retry_wexists(const string path, watcher_fn watcher, void* ctx,
																	 struct Stat* stat, struct timespec* ts, int retry, int& zerr) {
	int zret = ZCONNECTIONLOSS;
	int count = 0;
	while (zret == ZCONNECTIONLOSS && count < retry) {
		zret = zoo_wexists(this->_zh, path.c_str(), watcher, ctx, stat);
		if (zret == ZCONNECTIONLOSS) {
			log_info("connectionloss while setting watch on my predecessor (%s) - %s", zerror(zret), this->_message.c_str());
			nanosleep(ts, 0);
			count++;
		}
	}
	zerr = zret;
	return (zret == ZOK)?0:-1;
}

int zookeeper_lock::_child_floor(vector<string>& nodevector, const string& node, string& lessthanme) {
	int ret = -1;

	for (vector<string>::iterator it = nodevector.begin(); it != nodevector.end(); it++) {
		less_than_with_suffix less;
		if (less(*it, node)) {
			lessthanme = *it;
			ret = 0;
		}
	}
	return ret;
}

/*
 * aquire or wait for lock znode
 *
 * If the top of the queue is my id, it means that I am the owner of the lock.
 * Otherwise, we need to watch the predecessor to wait until the next chance.
 * 
 */
int zookeeper_lock::_lock_operation(bool again, int& zerr) {
	const string path = this->_path;
	struct Stat stat;
	string owner_id;
	int retry = 3;

	if (again && this->_id.empty()) {
		zerr = ZOK;
		return 0;
	}

	try {
		do {
			vector<string> nodevector;
			if (this->_retry_getchildren(path, nodevector, retry, zerr) < 0) {
				if (zerr != ZOK) {
					log_warning("failed to get children of %s (%s) - %s", path.c_str(), zerror(zerr), this->_message.c_str());
					throw -1;
				}
			}
			string child;
			if (this->_lookup_node(nodevector, this->_prefix, child) == 0) {
				this->_id = child;
			} else {
				this->_id.clear();
			}
			if (this->_id.empty()) {
				ostringstream mypath_oss;
				mypath_oss << path << '/' << this->_prefix;
				string mypath = mypath_oss.str();
				size_t sequence_len = 64; // we need extra bytes for serial number
				size_t retbuflen = mypath.size()+sequence_len+sizeof('\0');
#if (ZOO_MAJOR_VERSION <= 3 && ZOO_MINOR_VERSION < 4) // < 3.4
				retbuflen += path.size(); // workaround for ZOOKEEPER-1027
#endif
				char* retbuf = new char[retbuflen];
				string message = this->_message + " (" + this->_id + ")";
				zerr = zoo_create(this->_zh, mypath.c_str(), message.c_str(), message.size(), this->_acl, 
													ZOO_EPHEMERAL|ZOO_SEQUENCE, retbuf, retbuflen-sizeof('\0'));
				string resulted_path(retbuf);
				delete[] retbuf;
				if (zerr != ZOK) {
					log_warning("could not create zoo node %s (%s) - %s", mypath.c_str(), zerror(zerr), this->_message.c_str());
					throw -1;
				}
				vector<string> pathnodes;
				algorithm::split(pathnodes, resulted_path, is_any_of("/"));
				if (pathnodes.size() == 0) {
					log_err("failed to split resulted path %s - %s", resulted_path.c_str(), this->_message.c_str());
					throw -1;
				}
				log_info("create lock node %s - %s", resulted_path.c_str(), this->_message.c_str());
				this->_id = pathnodes.back();
			}
			if (!this->_id.empty()) {
				if (this->_retry_getchildren(path, nodevector, retry, zerr) < 0) {
					if (zerr != ZOK) {
						log_warning("could not connect to server (%s)", zerror(zerr));
						throw -1;
					} else if (nodevector.empty()) {
						log_warning("failed to fetch child nodes of %s", path.c_str());
						this->_id.clear();
						continue;
					}
				}
				std::sort(nodevector.begin(), nodevector.end(), less_than_with_suffix());
				owner_id = nodevector.front();
				this->_owner_id = owner_id;
				string id = this->_id;
				string lessthanme;
				if (this->_child_floor(nodevector, id, lessthanme) < 0) {
					// this is the case when we are the owner of the lock
					if (this->_id == owner_id) {
						log_info("got the zoo lock owner - %s", nickname(this->_id).c_str());
						pthread_mutex_lock(&this->_mutex_ownership);
						this->_is_owner = true;
						pthread_cond_broadcast(&this->_cond_ownership);
						pthread_mutex_unlock(&this->_mutex_ownership);
						this->_invoke_locked();
						throw 0;
					}
				} else {
					ostringstream last_child_oss;
					last_child_oss << path << '/' << lessthanme;
					string last_child = last_child_oss.str();
					log_debug("(%s -> %s) - %s", nickname(this->_id).c_str(), nickname(last_child).c_str(), this->_message.c_str());
	
					int ret = this->_retry_wexists(last_child, &zookeeper_lock::_lock_watcher_fn,
																				 (void *) this, &stat, &(this->_wait_ts), retry, zerr);
					// cannot watch my predecessor i am giving up
					// we need to be able to watch the predecessor 
					// since if we do not become a leader the others 
					// will keep waiting
					if (ret < 0) {
						if (zerr == ZNONODE) {
							log_notice("retry to watch the predecessor <%s> [%s] (%s) - %s",
												 nickname(last_child).c_str(), nickname(this->_id).c_str(), zerror(zerr), this->_message.c_str());
							continue;
						}
						log_warning("unable to watch the predecessor <%s> [%s] (%s) - %s",
												nickname(last_child).c_str(), nickname(this->_id).c_str(), zerror(zerr), this->_message.c_str());
						do {
							ret = this->_unlock_internal(zerr);
						} while (ret < 0);
						throw ret;
					}
					log_info("watch <%s> - %s", last_child.c_str(), this->_message.c_str());
					// we are not the owner of the lock
					pthread_mutex_lock(&this->_mutex_ownership);
					this->_is_owner = false;
					pthread_cond_broadcast(&this->_cond_ownership);
					pthread_mutex_unlock(&this->_mutex_ownership);
				}
				throw 0;
			}
			if (this->_id.empty()) {
				log_info("try again [%s] - %s", this->_path.c_str(), this->_message.c_str());
			}
		} while (this->_id.empty());
	} catch (int e) {
		return e;
	}
	return 0;
}

int zookeeper_lock::_lock_internal(bool again, int& zerr) {
	const int retry_count_for_lock = zookeeper_lock::default_retry_count;
	string path = this->_path;

	log_info("lock_internal (zh=%p path=%s) - %s", this->_zh, path.c_str(), this->_message.c_str());

	struct Stat stat;
	zerr = zoo_exists(this->_zh, path.c_str(), 0, &stat);
	for (int count = 0; (zerr == ZCONNECTIONLOSS || zerr == ZNONODE) && count < retry_count_for_lock; count++) {
		// retry the operation
		if (zerr == ZCONNECTIONLOSS) {
			nanosleep(&(this->_wait_ts), 0);
			zerr = zoo_exists(this->_zh, path.c_str(), 0, &stat);
		} else if (zerr == ZNONODE) {
			zerr = zoo_create(this->_zh, path.c_str(), NULL, -1, this->_acl, 0, NULL, 0);
		} else {
			log_warning("failed to check lock parent [%s] (%s) - %s", path.c_str(), zerror(zerr), this->_message.c_str());
		}
	}

	if (zerr != ZOK) {
		log_warning("no lock parent [%s] (%s) - %s", path.c_str(), zerror(zerr), this->_message.c_str());
		return -1;
	}

	return this->_lock_operation(again, zerr);
}

int zookeeper_lock::_unlock_internal(int& zerr) {
	ostringstream path_oss;
	path_oss << this->_path << '/' << this->_id;
	string path = path_oss.str();

	log_info("unlock_internal (zh=%p path=%s) - %s", this->_zh, path.c_str(), this->_message.c_str());

	if (this->_id.empty()) {
		return 0;
	}
	const int retry_count_for_unlock = zookeeper_lock::default_retry_count;
	int count = 0;
	zerr = ZCONNECTIONLOSS;
	while (zerr == ZCONNECTIONLOSS && count < retry_count_for_unlock) {
		zerr = zoo_delete(this->_zh, path.c_str(), -1);
		if (zerr != ZOK) {
			log_info("failed to delete [%s] - %s", nickname(path).c_str(), this->_message.c_str());
		}
		if (zerr == ZCONNECTIONLOSS) {
			log_notice("connection loss while deleting the znode %s - %s", path.c_str(), this->_message.c_str());
			nanosleep(&(this->_wait_ts), 0);
			count++;
		}
	}

	if (zerr == ZOK || zerr == ZNONODE) {
		this->_invoke_unlocked();
		this->_reset_lock();
		log_info("unlocked [%s] (%s) - %s", nickname(path).c_str(), zerror(zerr), this->_message.c_str());
		return 0;
	} else {
		log_warning("not able to connect to server, giving up [%s] - %s", nickname(path).c_str(), this->_message.c_str());
		return -1;
	}
}

int zookeeper_lock::_reset_lock() {
	uuid_t uuid;
	char prefix[64]; // we need 37 bytes for the string representation of uuid
	uuid_generate(uuid);
	uuid_unparse(uuid, prefix);
	for (int i = 0; prefix[i] && i < sizeof(prefix); i++) {
		prefix[i] = tolower(prefix[i]);
	}
	this->_prefix = string(prefix)+"-lock-";
	pthread_mutex_lock(&this->_mutex_ownership);
	this->_is_owner = false;
	pthread_mutex_unlock(&this->_mutex_ownership);
	this->_id.clear();
	this->_owner_id.clear();
	this->_message.clear();
	return 0;
}

int zookeeper_lock::_assure_session_connected() {
	pthread_mutex_lock(&(this->_mutex_session_state));
	session_state s = this->_session_state;
	while (s != session_state_active && s != session_state_finished) {
		log_notice("not connected [%s] - %s", this->_path.c_str(), this->_message.c_str());
		pthread_cond_wait(&this->_cond_session_state, &this->_mutex_session_state);	
	}
	pthread_mutex_unlock(&(this->_mutex_session_state));
	return (s == session_state_active)?0:-1;
}

void zookeeper_lock::_lock_watcher_fn(zhandle_t* zh, int type, int state,
																			const char* path, void *watcherCtx) {
	zookeeper_lock* self = (zookeeper_lock*) watcherCtx;
	self->_handle_lock_watch_event(type, state, string(path));
}

void zookeeper_lock::_global_watcher_fn(zhandle_t* zh, int type, int state,
																				const char* path, void* watcherCtx) {
	zookeeper_lock* self = reinterpret_cast<zookeeper_lock *>(watcherCtx);
	self->_handle_global_watch_event(type, state, string(path));
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
