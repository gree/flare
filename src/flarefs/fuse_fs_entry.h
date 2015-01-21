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
 *	fuse_fs_entry.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	FUSE_FS_ENTRY_H
#define	FUSE_FS_ENTRY_H

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

#include <fstream>
#include <sstream>

#include <boost/archive/binary_oarchive.hpp>
#include <boost/archive/binary_iarchive.hpp>
#include <boost/serialization/serialization.hpp>
#include <boost/serialization/string.hpp>
#include <boost/serialization/vector.hpp>
#include <boost/serialization/map.hpp>
#include <boost/serialization/split_member.hpp>
#include <boost/serialization/version.hpp>
#include <boost/lexical_cast.hpp>

#include "flarefs.h"

namespace gree {
namespace flare {

typedef class fuse_fs fuse_fs;
typedef class fuse_fs_entry fuse_fs_entry;
typedef shared_ptr<fuse_fs_entry> shared_fs_entry;   

namespace fuse_fs_entry_const {
} // namespace fuse_fs_entry_const

/**
 *	flarefs file system entry implementation
 */
class fuse_fs_entry {
public:
	enum 								type {
		type_none					= 0,
		type_dir,
		type_file,
	};

	typedef	pair<uint64_t, uint64_t> chunk_id_t;
	typedef	vector<chunk_id_t> chunk_list_t;

protected:
	string								_path;
	fuse_fs*							_fs;

	shared_client					_client;
	type									_type;
	uint64_t							_version;

	int										_access;
	int										_uid;
	int										_gid;
	off_t									_size;
	time_t								_atime;
	time_t								_ctime;
	time_t								_mtime;

	map<string, string>		_xattr;

	int										_chunk_size;
	chunk_list_t					_chunk_list;

public:
	static const int cas_retry_max = 8;
	static const int cas_retry_wait = 500;

	fuse_fs_entry(string path, fuse_fs* fs);
	virtual ~fuse_fs_entry();

	static shared_fs_entry create(string path, type t, fuse_fs* fs);
	static op::result get(string path, fuse_fs* fs, shared_fs_entry& fe);

	string get_path() { return this->_path; };
	type get_type() { return this->_type; };
	int get_parent(shared_fs_entry& fe);
	string get_parent_path();
	virtual int add_fs_entry(shared_fs_entry fe);

	int get_access() { return this->_access; };
	int set_access(int m) { this->_access = m; return 0; };
	int get_uid() { return this->_uid; };
	int set_uid(int uid) { this->_uid = uid; return 0; };
	int get_gid() { return this->_gid; };
	int set_gid(int gid) { this->_gid = gid; return 0; };
	off_t get_size() { return this->_size; };
	time_t get_atime() { return this->_atime; };
	time_t get_ctime() { return this->_ctime; };
	time_t get_mtime() { return this->_mtime; };

	inline int get_mode() {
		int m = this->_access;
		switch (this->_type) {
		case type_dir:
			m |= S_IFDIR;
			break;
		case type_file:
			m |= S_IFREG;
			break;
		default:
			break;
		}
		return m;
	};
	struct stat get_stat();
	int set_xattr(const char* name, const char* value, size_t value_size, int flag);
	int get_xattr(const char* name, char* value, size_t value_size);
	virtual int get_dirent(off_t o, string& name, struct stat& st);

	virtual const char* serialize(int& data_size);
	virtual int unserialize(const char* data, int data_size, uint64_t version);
	int reload();
	op::result store(bool force = false);

protected:
	friend class boost::serialization::access;
	BOOST_SERIALIZATION_SPLIT_MEMBER();

	template<class Archive> void save(Archive& ar, const unsigned int version) const {
		log_debug("version: %d", version);

		log_debug("access: %d", this->_access);
		ar & this->_access;
		log_debug("uid: %d", this->_uid);
		ar & this->_uid;
		log_debug("gid: %d", this->_gid);
		ar & this->_gid;
		log_debug("size: %d", this->_size);
		ar & this->_size;
		log_debug("atime: %d", this->_atime);
		ar & this->_atime;
		log_debug("ctime: %d", this->_ctime);
		ar & this->_ctime;
		log_debug("mtime: %d", this->_mtime);
		ar & this->_mtime;
		log_debug("xattr: size=%d", this->_xattr.size());
		ar & this->_xattr;
		log_debug("chunk_list: size=%d", this->_chunk_list.size());
		ar & this->_chunk_list;
	};

	template<class Archive> void load(Archive& ar, const unsigned int version) {
		log_debug("version: %d", version);
		switch (version) {
		case 1:
			ar & this->_access;
			log_debug("access: %d", this->_access);
			ar & this->_uid;
			log_debug("uid: %d", this->_uid);
			ar & this->_gid;
			log_debug("gid: %d", this->_gid);
			ar & this->_size;
			log_debug("size: %d", this->_size);
			ar & this->_atime;
			log_debug("atime: %d", this->_atime);
			ar & this->_ctime;
			log_debug("ctime: %d", this->_ctime);
			ar & this->_mtime;
			log_debug("mtime: %d", this->_mtime);
			ar & this->_xattr;
			log_debug("xattr: size=%d", this->_xattr.size());
			ar & this->_chunk_list;
			log_debug("chunk_list: size=%d", this->_chunk_list.size());

			break;
		}
	};

private:
};

}	// namespace flare
}	// namespace gree

BOOST_CLASS_VERSION(gree::flare::fuse_fs_entry, 1);

#endif	// FUSE_FS_ENTRY_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
