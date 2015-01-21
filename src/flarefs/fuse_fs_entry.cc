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
 *	fuse_fs_entry.cc
 *
 *	implementation of gree::flare::fuse_fs_entry
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "fuse_fs.h"
#include "fuse_fs_entry.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for fuse_fs_entry
 */
fuse_fs_entry::fuse_fs_entry(string path, fuse_fs* fs):
		_path(path),
		_fs(fs),
		_version(0),
		_access(0),
		_uid(0),
		_gid(0),
		_size(0),
		_atime(0),
		_ctime(0),
		_mtime(0),
		_chunk_size(0) {
	this->_client = fs->get_client();
	this->_chunk_size = fs->get_chunk_size();
	this->_type = type_none;
}

/**
 *	dtor for fuse_fs_entry
 */
fuse_fs_entry::~fuse_fs_entry() {
	this->_fs->push_client(this->_client);
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	create blank fs entry object
 */
shared_fs_entry fuse_fs_entry::create(string path, type t, fuse_fs* fs) {
	shared_fs_entry fe;
	if (t == type_dir) {
		fe = shared_fs_entry(new fuse_fs_entry_dir(path, fs));
	} else if (t == type_file) {
		fe = shared_fs_entry(new fuse_fs_entry_file(path, fs));
	} else {
		log_err("unknown fs entry type (type=%d)", t);
		// will cause assertion error
	}

	return fe;
}

/**
 *	get existing fs entry object
 */
op::result fuse_fs_entry::get(string path, fuse_fs* fs, shared_fs_entry& fe) {
	storage::entry e;
	shared_client c = fs->get_client();
	op::result r = c->gets(path, e);
	fs->push_client(c);
	if (r < 0 || r == op::result_not_found) {
		log_debug("result: %s -> no entry object created", op::result_cast(r).c_str());
		return op::result_error;
	}

	if (e.flag == type_dir) {
		fe = shared_fs_entry(new fuse_fs_entry_dir(path, fs));
	} else if (e.flag == type_file) {
		fe = shared_fs_entry(new fuse_fs_entry_file(path, fs));
	} else {
		log_err("unknown fs entry type (flag=%d)", e.flag);
		return op::result_error;
	}

	fe->unserialize((const char*)e.data.get(), e.size, e.version);

	return op::result_ok;
}

/**
 *	get parent fs entry object
 */
int fuse_fs_entry::get_parent(shared_fs_entry& fe) {
	string path = this->get_parent_path();

	if (fuse_fs_entry::get(path, this->_fs, fe) < 0) {
		return -1;
	}
	if (fe->get_type() != type_dir) {
		log_warning("type of parent fs entry object is not directory (type=%d)...something is going wrong", fe->get_type());
		return -1;
	}

	return 0;
}

/**
 *	get parent path name
 */
string fuse_fs_entry::get_parent_path() {
	if (this->_path == "/") {
		return "/";
	}

	// assume that this->_path is normalized
	string::size_type n = this->_path.find_last_of('/');
	if (n == string::npos) {
		log_warning("could not find last '/' (path=%s)", this->_path.c_str());
		return "/";
	}

	string r = this->_path.substr(0, n);
	log_debug("%s -> %s", this->_path.c_str(), r.c_str());

	return r;
}

/**
 *	add new fs entry
 */
int fuse_fs_entry::add_fs_entry(shared_fs_entry fe) {
	log_warning("fs entry type=%d does not support this operation", this->_type);

	return 0;
}

/**
 *	get stat struct
 */
struct stat fuse_fs_entry::get_stat() {
	struct stat st;
	memset(&st, 0, sizeof(st));

	// ignore
	// - st_dev
	// - st_ino
	// - st_nlink
	// - st_rdev
	// - st_blksize

	st.st_mode = this->get_mode();
	st.st_uid = this->_uid;
	st.st_gid = this->_gid;
	st.st_size = this->_size;
	st.st_blocks = this->_chunk_list.size();
	st.st_atime = this->_atime;
	st.st_ctime = this->_ctime;
	st.st_mtime = this->_mtime;

	return st;
}

/**
 *	set extended attr
 */
int fuse_fs_entry::set_xattr(const char* name, const char* value, size_t value_size, int flag) {
	int n = fuse_fs_entry::cas_retry_max;
	do {
		if (flag == XATTR_CREATE && this->_xattr.find(name) != this->_xattr.end()) {
			log_notice("xattr_create flag is specified but already exists (name=%s)", name);
			return -EEXIST;
		} else if (flag == XATTR_REPLACE && this->_xattr.find(name) == this->_xattr.end()) {
			log_notice("xattr_replace flag is specified but not found (name=%s)", name);
			return -ENOENT;
		}

		this->_xattr[name] = util::base64_encode(value, value_size);
		op::result r = this->store();
		if (r == op::result_stored) {
			log_debug("storing xattr successfully done (path=%s, name=%s)", this->_path.c_str(), name);
			return 0;
		} else if (r == op::result_not_found) {
			log_info("fs entry not found (perhaps removed by another request) (path=%s, name=%s)", this->_path.c_str(), name);
			return -ENOENT;
		}

		// reload + retry
		if (this->reload() < 0) {
			log_info("fs entry reloading failed", 0);
			return -ENOENT;
		}

		usleep(fuse_fs_entry::cas_retry_wait);
	} while (--n > 0);

	return 0;
}

/**
 *	get extended attr
 */
int fuse_fs_entry::get_xattr(const char* name, char* value, size_t value_size) {
	if (this->_xattr.find(name) == this->_xattr.end()) {
		log_debug("xattr not found (name=%s)", name);
		return 0;		// pretend ok
	}

	size_t data_size;
	char* data = util::base64_decode(this->_xattr[name], data_size);
	if (data_size > value_size) {
		log_warning("xattr value size exceeded (name=%s, data_size=%d, value_size=%d)", name, data_size, value_size);
		delete[] data;
		return -ERANGE;
	}

	memcpy(value, data, data_size);
	delete[] data;

	log_debug("name=%s, data_size=%d", name, data_size);

	return 0;
}

/**
 *	get_dirent
 */
int fuse_fs_entry::get_dirent(off_t o, string& name, struct stat& st) {
	log_warning("fs entry type=%d does not support this operation", this->_type);

	return 0;
}

/**
 *	reload
 */
int fuse_fs_entry::reload() {
	storage::entry e;
	op::result r = this->_client->gets(this->_path, e);
	if (r < 0 || r == op::result_not_found) {
		log_debug("result: %s -> fs entry has gone away", op::result_cast(r).c_str());
		return -1;
	}
	if (e.flag != static_cast<uint>(this->_type)) {
		log_warning("fs entry type changed (%d -> %d)...something is going wrong", this->_type, e.flag);
		return -1;
	}

	this->unserialize((const char*)e.data.get(), e.size, e.version);

	return 0;
}

/**
 *	add fs entry object to stroage
 */
op::result fuse_fs_entry::store(bool force) {
	time_t t = time(NULL);
	this->_atime = this->_mtime = t;
	if (this->_version == 0) {
		this->_ctime = t;
	}

	int data_size;
	const char* data = this->serialize(data_size);

	op::result r = op::result_ok;
	if (this->_version == 0) {
		r = this->_client->add(this->_path, data, data_size, this->_type);
	} else {
		r = this->_client->cas(this->_path, data, data_size, this->_type, this->_version);
	}

	delete[] data;

	return r;
}
// }}}

// {{{ protected methods
/**
 *	serialize fs entry object
 */
const char* fuse_fs_entry::serialize(int& data_size) {
	ostringstream s;

	archive::binary_oarchive oa(s);
	oa << (const fuse_fs_entry&)*this;

	data_size = s.str().size()+1;
	char* data = new char[data_size];
	memcpy(data, s.str().c_str(), data_size);

	return data;
}

/**
 *	unserialize fs entry object
 */
int fuse_fs_entry::unserialize(const char* data, int data_size, uint64_t version) {
	string tmp(data, data_size);
	istringstream s(tmp, istringstream::in | istringstream::binary);

	archive::binary_iarchive ia(s);

	ia >> *this;

	this->_version = version;

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
