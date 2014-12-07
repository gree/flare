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
 *	fuse_fs.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	FUSE_FS_H
#define	FUSE_FS_H

#include "flarefs.h"
#include "fuse_fs_entry.h"
#include "fuse_fs_entry_dir.h"
#include "fuse_fs_entry_file.h"

namespace gree {
namespace flare {

namespace fuse_fs_const {
	static const string chunk_id_key("__chunk_id__");
} // namespace fuse_fs_const

/**
 *	flarefs file system implementation
 */
class fuse_fs {
public:
	typedef stack<shared_client>				client_pool;

private:
	unsigned int												_fh_index;
	int																	_chunk_size;
	client_pool::size_type							_client_pool_size;
	string															_node_server_name;
	int																	_node_server_port;
	client_pool													_pool;

	pthread_mutex_t											_mutex_pool;

public:
	static const int 										root_access = 0755;

	fuse_fs(string node_server_name, int node_server_port, int chunk_size, client_pool::size_type client_pool_size);
	~fuse_fs();

	int get_chunk_size() { return this->_chunk_size; };

	int init();

	int getattr(string path, struct stat* st);
	int setxattr(string path, const char* name, const char* value, size_t value_size, int flag);
	int getxattr(string path, const char* name, char* value, size_t value_size);

	int mkdir(string path, mode_t m);
	int opendir(string path, struct fuse_file_info* fi);
	int readdir(string path, void* buf, fuse_fill_dir_t filler, off_t o, struct fuse_file_info* fi);

	shared_client get_client();
	int push_client(shared_client c);

protected:

private:
	int _init_chunk_id();
	unsigned int _get_fh_id();
};

}	// namespace flare
}	// namespace gree

#endif	// FUSE_FS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
