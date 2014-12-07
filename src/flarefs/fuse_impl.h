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
 *	fuse_impl.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	FUSE_IMPL_H
#define	FUSE_IMPL_H

#include "flarefs.h"
#include "fuse_fs.h"

namespace gree {
namespace flare {

/**
 *	fuse implementation class for flarefs
 */
class fuse_impl {
private:
	bool				_allow_other;
	bool				_allow_root;
	fuse_fs*		_fs;
	string			_mount_dir;

public:
	fuse_impl(string mount_dir);
	~fuse_impl();

	int run();

	int set_allow_other(bool flag) { this->_allow_other = flag; return 0; };
	int set_allow_root(bool flag) { this->_allow_root = flag; return 0; };

	int getattr(const char* path, struct stat* st);
	int readlink(const char* src_path, char* dst_path, size_t dst_path_size);
	int mknod(const char* path, mode_t m, dev_t d);
	int mkdir(const char* path, mode_t m);
	int unlink(const char* path);
	int rmdir(const char* path);
	int symlink(const char* src_path, const char* dst_path);
	int rename(const char* src_path, const char* dst_path);
	int link(const char* src_path, const char* dst_path);
	int chmod(const char* path, mode_t m);
	int chown(const char* path, uid_t u, gid_t g);
	int truncate(const char* path, off_t o);
	int utime(const char* path, struct utimbuf* u);
	int open(const char* path, struct fuse_file_info* f);
	int read(const char* path, char* buf, size_t buf_size, off_t o, struct fuse_file_info* f);
	int write(const char* path, const char* buf, size_t buf_size, off_t o, struct fuse_file_info* f);
	int statfs(const char* path, struct statvfs* st);
	int flush(const char* path, struct fuse_file_info* f);
	int release(const char* path, struct fuse_file_info* f);
	int fsync(const char* path, int m, struct fuse_file_info* f);
	int setxattr(const char* path, const char* name, const char* value, size_t value_size, int m); 
	int getxattr(const char* path, const char* name, char* value, size_t value_size);
	int listxattr(const char* path, char* buf, size_t buf_size);
	int removexattr(const char* path, const char* name);
	int opendir(const char* path, struct fuse_file_info* fi);
	int readdir(const char* path, void* buf, fuse_fill_dir_t filler, off_t o, struct fuse_file_info* fi);
	int fsyncdir(const char* path, int m, struct fuse_file_info* f);
	void* init();
	void destroy(void* buf);
	int access(const char* path, int m);
	int create(const char* path, mode_t m, struct fuse_file_info* f);
	int ftruncate(const char* path, off_t o, struct fuse_file_info* f) ;
	int fgetattr(const char* path, struct stat* st, struct fuse_file_info* f);

protected:

private:
};

}	// namespace flare
}	// namespace gree

#endif	// FUSE_IMPL_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
