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
 *	fuse_fs.cc
 *
 *	implementation of gree::flare::fuse_fs
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "fuse_fs.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for fuse_fs
 */
fuse_fs::fuse_fs(string node_server_name, int node_server_port, int chunk_size, fuse_fs::client_pool::size_type client_pool_size):
		_fh_index(8),
		_chunk_size(chunk_size),
		_client_pool_size(client_pool_size),
		_node_server_name(node_server_name),
		_node_server_port(node_server_port) {
	pthread_mutex_init(&this->_mutex_pool, NULL);
}

/**
 *	dtor for fuse_fs
 */
fuse_fs::~fuse_fs() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	initialize fs (not format)
 */
int fuse_fs::init() {
	if (this->_init_chunk_id() < 0) {
		log_err("initializing chunk id failed -> skip initialization...", 0);
		return -1;
	}

	shared_fs_entry fe;
	if (fuse_fs_entry::get("/", this, fe) < 0) {
		log_info("no root('/') fs entry -> creating...", 0);
		fe = fuse_fs_entry::create("/", fuse_fs_entry::type_dir, this);
		fe->set_access(fuse_fs::root_access);
		if (fe->store() < 0) {
			log_err("adding fs entry failed (path=%s)", fe->get_path().c_str());
			return -1;
		}
		log_info("root('/') fs entry successfully created", 0);
	}

	return 0;
}

/**
 *	getattr
 */
int fuse_fs::getattr(string path, struct stat* st) {
	shared_fs_entry fe;
	if (fuse_fs_entry::get(path, this, fe) < 0) {
		log_info("fs entry not found (path=%s)", path.c_str());
		return -ENOENT;
	}

	*st = fe->get_stat();

	return 0;
}

/**
 *	setxattr
 */
int fuse_fs::setxattr(string path, const char* name, const char* value, size_t value_size, int flag) {
	shared_fs_entry fe;
	if (fuse_fs_entry::get(path, this, fe) < 0) {
		log_info("fs entry not found (path=%s)", path.c_str());
		return -ENOENT;
	}

	return fe->set_xattr(name, value, value_size, flag);
}

/**
 *	getxattr
 */
int fuse_fs::getxattr(string path, const char* name, char* value, size_t value_size) {
	shared_fs_entry fe;
	if (fuse_fs_entry::get(path, this, fe) < 0) {
		log_info("fs entry not found (path=%s)", path.c_str());
		return -ENOENT;
	}

	return fe->get_xattr(name, value, value_size);
}

/**
 *	mkdir
 */
int fuse_fs::mkdir(string path, mode_t m) {
	shared_fs_entry fe = fuse_fs_entry::create(path, fuse_fs_entry::type_dir, this);
	fe->set_access(m);
	shared_fs_entry fe_parent;
	if (fe->get_parent(fe_parent) < 0) {
		return -ENOENT;
	}
	op::result r = fe->store();
	if (r < 0) {
		return -EFAULT;
	} else if (r != op::result_stored) {
		return -EEXIST;
	}

	if (fe_parent->add_fs_entry(fe) < 0) {
		return -EFAULT;
	}

	return 0;
}

/**
 *	opendir
 */
int fuse_fs::opendir(string path, fuse_file_info* fi) {
	shared_fs_entry fe;
	if (fuse_fs_entry::get(path, this, fe) < 0) {
		log_info("fs entry not found (path=%s)", path.c_str());
		return -ENOENT;
	}
	if (fe->get_type() != fuse_fs_entry::type_dir) {
		log_info("not directory (path=%s, type=%d)", path.c_str(), fe->get_type());
		return ENOTDIR;
	}

	// TODO: map to something?
	fi->fh = this->_get_fh_id();

	return 0;
}

/**
 *	readdir
 */
int fuse_fs::readdir(string path, void* buf, fuse_fill_dir_t filler, off_t o, struct fuse_file_info* fi) {
	shared_fs_entry fe;
	if (fuse_fs_entry::get(path, this, fe) < 0) {
		log_info("fs entry not found (path=%s)", path.c_str());
		return -ENOENT;
	}
	if (fe->get_type() != fuse_fs_entry::type_dir) {
		log_info("not directory (path=%s, type=%d)", path.c_str(), fe->get_type());
		return ENOTDIR;
	}

	int r = 0;
	off_t i = o;
	do {
		string name;
		struct stat st;
		if (fe->get_dirent(i, name, st) < 0) {
			log_warning("failed to get directory entry (offset=%d) -> continue processing", i);
			i++;
			continue;
		}
		if (name.empty()) {
			break;
		}
		i++;

		log_debug("adding dirent (name=%s, next offset=%d)", name.c_str(), i);
		r = filler(buf, name.c_str(), &st, i);
	} while (r == 0);

	return 0;
}

/**
 *	get client object from pool (if none, create object)
 */
shared_client fuse_fs::get_client() {
	shared_client c;

	pthread_mutex_lock(&this->_mutex_pool);
	int pool_size = this->_pool.size();
	log_debug("current pool size: %d", pool_size);
	if (pool_size > 0) {
		c = this->_pool.top();
		this->_pool.pop();
		log_debug("client object from pool", 0);
	} else {
		c = shared_client(new client(this->_node_server_name, this->_node_server_port));
	}
	pthread_mutex_unlock(&this->_mutex_pool);

	// no error check
	c->connect();

	return c;
}

/**
 *	push back client object to pool
 */
int fuse_fs::push_client(shared_client c) {
	pthread_mutex_lock(&this->_mutex_pool);
	if (this->_pool.size() < this->_client_pool_size) {
		log_debug("adding client object to pool (current_size=%d)", this->_pool.size());
		this->_pool.push(c);
	} else {
		log_debug("pool has already enough objects (%d objects) -> skip pooling", this->_pool.size());
		// nop
	}
	pthread_mutex_unlock(&this->_mutex_pool);

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
/**
 *	initialize chunk id
 */
int fuse_fs::_init_chunk_id() {
	shared_client c = this->get_client();
	if (c->is_available() == false) {
		log_err("failed to get client", 0);
		return -1;
	}

	// add initial data anyway
	op::result r = c->add(fuse_fs_const::chunk_id_key, 0);
	if (r < 0) {
		log_err("failed to add initial chunk id entry", 0);
		this->push_client(c);
		return -1;
	}

	// do not care about result code here
	log_debug("added initial chunkd id entry (result=%s)", op::result_cast(r).c_str());

	this->push_client(c);

	return 0;
}

/**
 *	get next fh id
 */
unsigned int fuse_fs::_get_fh_id() {
	unsigned int tmp;
	ATOMIC_ADD(&this->_fh_index, 1, tmp);

	return tmp;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
