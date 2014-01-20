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
