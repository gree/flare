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
 *	fuse_fs_entry_file.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	FUSE_FS_ENTRY_FILE_H
#define	FUSE_FS_ENTRY_FILE_H

#include "flarefs.h"
#include "fuse_fs_entry.h"

namespace gree {
namespace flare {

namespace fuse_fs_entry_file_const {
} // namespace fuse_fs_entry_file_const

/**
 *	flarefs file system entry_file implementation
 */
class fuse_fs_entry_file : public fuse_fs_entry {
public:

private:

public:
	fuse_fs_entry_file(string path, fuse_fs* fs);
	~fuse_fs_entry_file();

protected:

private:
};

}	// namespace flare
}	// namespace gree

#endif	// FUSE_FS_ENTRY_FILE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
