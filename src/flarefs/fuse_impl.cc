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
 *	fuse_impl.cc
 *
 *	implementation of gree::flare::fuse_impl (and some other global stuffs)
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "fuse_impl.h"

namespace gree {
namespace flare {

static fuse_impl* fuse_obj = NULL;

// {{{ global functions
int fuse_impl_getattr(const char* path, struct stat* st) {
	return fuse_obj->getattr(path, st);
}

int fuse_impl_readlink(const char* src_path, char* dst_path, size_t dst_path_size) {
	return fuse_obj->readlink(src_path, dst_path, dst_path_size);
}

int fuse_impl_mknod(const char* path, mode_t m, dev_t d) {
	return fuse_obj->mknod(path, m, d);
}

int fuse_impl_mkdir(const char* path, mode_t m) {
	return fuse_obj->mkdir(path, m);
}

int fuse_impl_unlink(const char* path) {
	return fuse_obj->unlink(path);
}

int fuse_impl_rmdir(const char* path) {
	return fuse_obj->rmdir(path);
}

int fuse_impl_symlink(const char* src_path, const char* dst_path) {
	return fuse_obj->symlink(src_path, dst_path);
}

int fuse_impl_rename(const char* src_path, const char* dst_path) {
	return fuse_obj->rename(src_path, dst_path);
}

int fuse_impl_link(const char* src_path, const char* dst_path) {
	return fuse_obj->link(src_path, dst_path);
}

int fuse_impl_chmod(const char* path, mode_t m) {
	return fuse_obj->chmod(path, m);
}

int fuse_impl_chown(const char* path, uid_t u, gid_t g) {
	return fuse_obj->chown(path, u, g);
}

int fuse_impl_truncate(const char* path, off_t o) {
	return fuse_obj->truncate(path, o);
}

int fuse_impl_utime(const char* path, struct utimbuf* u) {
	return fuse_obj->utime(path, u);
}

int fuse_impl_open(const char* path, struct fuse_file_info* f) {
	return fuse_obj->open(path, f);
}

int fuse_impl_read(const char* path, char* buf, size_t buf_size, off_t o, struct fuse_file_info* f) {
	return fuse_obj->read(path, buf, buf_size, o, f);
}

int fuse_impl_write(const char* path, const char* buf, size_t buf_size, off_t o, struct fuse_file_info* f) {
	return fuse_obj->write(path, buf, buf_size, o, f);
}

int fuse_impl_statfs(const char* path, struct statvfs* st) {
	return fuse_obj->statfs(path, st);
}

int fuse_impl_flush(const char* path, struct fuse_file_info* f) {
	return fuse_obj->flush(path, f);
}

int fuse_impl_release(const char* path, struct fuse_file_info* f) {
	return fuse_obj->release(path, f);
}

int fuse_impl_fsync(const char* path, int m, struct fuse_file_info* f) {
	return fuse_obj->fsync(path, m, f);
}

int fuse_impl_setxattr(const char* path, const char* name, const char* value, size_t value_size, int flag) {
	return fuse_obj->setxattr(path, name, value, value_size, flag);
}

int fuse_impl_getxattr(const char* path, const char* name, char* value, size_t value_size) {
	return fuse_obj->getxattr(path, name, value, value_size);
}

int fuse_impl_listxattr(const char* path, char* buf, size_t buf_size) {
	return fuse_obj->listxattr(path, buf, buf_size);
}

int fuse_impl_removexattr(const char* path, const char* name) {
	return fuse_obj->removexattr(path, name);
}

int fuse_impl_opendir(const char* path, struct fuse_file_info* f) {
	return fuse_obj->opendir(path, f);
}

int fuse_impl_readdir(const char* path, void* buf, fuse_fill_dir_t d, off_t o, struct fuse_file_info* f) {
	return fuse_obj->readdir(path, buf, d, o, f);
}

int fuse_impl_fsyncdir(const char* path, int m, struct fuse_file_info* f) {
	return fuse_obj->fsyncdir(path, m, f);
}

void* fuse_impl_init() {
	return fuse_obj->init();
}

void fuse_impl_destroy(void* buf) {
	fuse_obj->destroy(buf);
}

int fuse_impl_access(const char* path, int m) {
	return fuse_obj->access(path, m);
}

int fuse_impl_create(const char* path, mode_t m, struct fuse_file_info* f) {
	return fuse_obj->create(path, m, f);
}

int fuse_impl_ftruncate(const char* path, off_t o, struct fuse_file_info* f) {
	return fuse_obj->ftruncate(path, o, f);
} 

int fuse_impl_fgetattr(const char* path, struct stat* st, struct fuse_file_info* f) {
	return fuse_obj->fgetattr(path, st, f);
}
// }}}

// {{{ ctor/dtor
/**
 *	ctor for fuse_impl
 */
fuse_impl::fuse_impl(string mount_dir):
		_allow_other(false),
		_allow_root(false),
		_fs(NULL),
		_mount_dir(mount_dir) {
}

/**
 *	dtor for fuse_impl
 */
fuse_impl::~fuse_impl() {
	delete this->_fs;
	this->_fs = NULL;
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	fuse main
 */
int fuse_impl::run() {
	if (fuse_obj != NULL) {
		log_err("fuse object seems to be already active -> skip running", 0);
		return -1;
	}
	fuse_obj = this;

	this->_fs = new fuse_fs(ini_option_object().get_node_server_name(), ini_option_object().get_node_server_port(), ini_option_object().get_chunk_size(), ini_option_object().get_connection_pool_size());

	fuse_operations fo;
	memset(&fo, 0, sizeof(fo));
	fo.getattr			= fuse_impl_getattr;
	fo.readlink			= fuse_impl_readlink;
	fo.mknod				= fuse_impl_mknod;
	fo.mkdir				= fuse_impl_mkdir;
	fo.unlink				= fuse_impl_unlink;
	fo.rmdir				= fuse_impl_rmdir;
	fo.symlink			= fuse_impl_symlink;
	fo.rename				= fuse_impl_rename;
	fo.link					= fuse_impl_link;
	fo.chmod				= fuse_impl_chmod;
	fo.chown				= fuse_impl_chown;
	fo.truncate			= fuse_impl_truncate;
	fo.utime				= fuse_impl_utime;
	fo.open					= fuse_impl_open;
	fo.read					= fuse_impl_read;
	fo.write				= fuse_impl_write;
	fo.statfs				= fuse_impl_statfs;
	fo.flush				= fuse_impl_flush;
	fo.release			= fuse_impl_release;
	fo.fsync				= fuse_impl_fsync;
	fo.setxattr			= fuse_impl_setxattr;
	fo.getxattr			= fuse_impl_getxattr;
	fo.listxattr		= fuse_impl_listxattr;
	fo.removexattr	= fuse_impl_removexattr;
	fo.opendir			= fuse_impl_opendir;
	fo.readdir			= fuse_impl_readdir;
	fo.fsyncdir			= fuse_impl_fsyncdir;
	fo.init					= fuse_impl_init;
	fo.destroy			= fuse_impl_destroy;
	fo.access				= fuse_impl_access;
	fo.create				= fuse_impl_create;
	fo.ftruncate		= fuse_impl_ftruncate;
	fo.fgetattr			= fuse_impl_fgetattr;

	int argc = 0;
	char* argv[BUFSIZ];		// BUFSIZ will do:)
	argv[argc++] = strdup(PACKAGE_NAME);
	argv[argc++] = strdup(this->_mount_dir.c_str());
	if (this->_allow_other || this->_allow_root) {
		argv[argc++] = strdup("-o");
	}
	if (this->_allow_other) {
		argv[argc++] = strdup("allow_other");
	} else if (this->_allow_root) {
		argv[argc++] = strdup("allow_root");
	}

	fuse_main(argc, argv, &fo);

	while (argc > 0) {
		free(argv[--argc]);
	}

	return 0;
}

/**
 *	getattr
 */
int fuse_impl::getattr(const char* path, struct stat* st) {
	log_debug("getattr() (path=%s)", path);

	return this->_fs->getattr(path, st);
}

/**
 *	readlink
 */
int fuse_impl::readlink(const char* src_path, char* dst_path, size_t dst_path_size) {
	log_debug("readlink() (src_path=%s)", src_path);

	return 0;
}

/**
 *	mknod
 */
int fuse_impl::mknod(const char* path, mode_t m, dev_t d) {
	log_debug("mknod() (path=%s)", path);

	return 0;
}

/**
 *	mkdir
 */
int fuse_impl::mkdir(const char* path, mode_t m) {
	log_debug("mkdir() (path=%s, mode=%d)", path, m);

	return this->_fs->mkdir(path, m);
}

/**
 *	unlink
 */
int fuse_impl::unlink(const char* path) {
	log_debug("unlink() (path=%s)", path);

	return 0;
}

/**
 *	rmdir
 */
int fuse_impl::rmdir(const char* path) {
	log_debug("rmdir() (path=%s)", path);

	return 0;
}

/**
 *	symlink
 */
int fuse_impl::symlink(const char* src_path, const char* dst_path) {
	log_debug("symlink() (src_path=%s, dst_path=%s)", src_path, dst_path);

	return 0;
}

/**
 *	rename
 */
int fuse_impl::rename(const char* src_path, const char* dst_path) {
	log_debug("rename() (src_path=%s, dst_path=%s)", src_path, dst_path);

	return 0;
}

/**
 *	link
 */
int fuse_impl::link(const char* src_path, const char* dst_path) {
	log_debug("link() (src_path=%s, dst_path=%s)", src_path, dst_path);

	return 0;
}

/**
 *	chmod
 */
int fuse_impl::chmod(const char* path, mode_t m) {
	log_debug("chmod() (path=%s, mode=%d)", path, m);

	return 0;
}

/**
 *	chown
 */
int fuse_impl::chown(const char* path, uid_t u, gid_t g) {
	log_debug("chown() (path=%s, uid=%d, gid=%d)", path, u, g);

	return 0;
}

/**
 *	truncate
 */
int fuse_impl::truncate(const char* path, off_t o) {
	log_debug("truncate() (path=%s, offset=%d)", path, o);

	return 0;
}

/**
 *	utime
 */
int fuse_impl::utime(const char* path, struct utimbuf* u) {
	log_debug("utime() (path=%s)", path);

	return 0;
}

/**
 *	open
 */
int fuse_impl::open(const char* path, struct fuse_file_info* f) {
	log_debug("open() (path=%s)", path);

	return 0;
}

/**
 *	read
 */
int fuse_impl::read(const char* path, char* buf, size_t buf_size, off_t o, struct fuse_file_info* f) {
	log_debug("read() (path=%s, offset=%d)", path, o);

	return 0;
}

/**
 *	write
 */
int fuse_impl::write(const char* path, const char* buf, size_t buf_size, off_t o, struct fuse_file_info* f) {
	log_debug("write() (path=%s, offset=%d)", path, o);

	return 0;
}

/**
 *	statfs
 */
int fuse_impl::statfs(const char* path, struct statvfs* st) {
	log_debug("statfs() (path=%s)", path);

	return 0;
}

/**
 *	flush
 */
int fuse_impl::flush(const char* path, struct fuse_file_info* f) {
	log_debug("flush() (path=%s)", path);

	return 0;
}

/**
 *	release
 */
int fuse_impl::release(const char* path, struct fuse_file_info* f) {
	log_debug("release() (path=%s)", path);

	return 0;
}

/**
 *	fsync
 */
int fuse_impl::fsync(const char* path, int m, struct fuse_file_info* f) {
	log_debug("fsync() (path=%s, mode=%d)", path, m);

	return 0;
}

/**
 *	setxattr
 */
int fuse_impl::setxattr(const char* path, const char* name, const char* value, size_t value_size, int flag) {
	log_debug("setxattr() (path=%s, name=%s, flag=%d)", path, name, flag);

	return this->_fs->setxattr(path, name, value, value_size, flag);
}

/**
 *	getxattr
 */
int fuse_impl::getxattr(const char* path, const char* name, char* value, size_t value_size) {
	log_debug("getxattr() (path=%s, name=%s)", path, name);

	return this->_fs->getxattr(path, name, value, value_size);
}

/**
 *	listxattr
 */
int fuse_impl::listxattr(const char* path, char* buf, size_t buf_size) {
	log_debug("listxattr() (path=%s)", path);

	return 0;
}

/**
 *	removexattr
 */
int fuse_impl::removexattr(const char* path, const char* name) {
	log_debug("removexattr() (path=%s, name=%s)", path, name);

	return 0;
}

/**
 *	opendir
 */
int fuse_impl::opendir(const char* path, struct fuse_file_info* fi) {
	log_debug("opendir() (path=%s)", path);

	return this->_fs->opendir(path, fi);
}

/**
 *	readdir
 */
int fuse_impl::readdir(const char* path, void* buf, fuse_fill_dir_t filler, off_t o, struct fuse_file_info* fi) {
	log_debug("readdir() (path=%s, offset=%d)", path, o);

	return this->_fs->readdir(path, buf, filler, o, fi);
}

/**
 *	fsyncdir
 */
int fuse_impl::fsyncdir(const char* path, int m, struct fuse_file_info* f) {
	log_debug("fsyncdir() (path=%s, mode=%d)", path, m);

	return 0;
}

/**
 *	init
 */
void* fuse_impl::init() {
	log_debug("init()", 0);

	this->_fs->init();

	return NULL;
}

/**
 *	destroy
 */
void fuse_impl::destroy(void* buf) {
	log_debug("destroy()", 0);
}

/**
 *	access
 */
int fuse_impl::access(const char* path, int m) {
	log_debug("access() (path=%s, mode=%d)", path, m);

	return 0;
}

/**
 *	create
 */
int fuse_impl::create(const char* path, mode_t m, struct fuse_file_info* f) {
	log_debug("create() (path=%s, mode=%d)", path, m);

	return 0;
}

/**
 *	ftruncate
 */
int fuse_impl::ftruncate(const char* path, off_t o, struct fuse_file_info* f) {
	log_debug("ftruncate() (path=%s, offset=%d)", path, o);

	return 0;
}

/**
 *	fgetattr
 */
int fuse_impl::fgetattr(const char* path, struct stat* st, struct fuse_file_info* f) {
	log_debug("fgetattr() (path=%s)", path);

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
