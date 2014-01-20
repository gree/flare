/**
 *	fuse_fs_entry_dir.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	FUSE_FS_ENTRY_DIR_H
#define	FUSE_FS_ENTRY_DIR_H

#include "flarefs.h"
#include "fuse_fs_entry.h"

namespace gree {
namespace flare {

namespace fuse_fs_entry_dir_const {
} // namespace fuse_fs_entry_dir_const

/**
 *	flarefs file system entry_dir implementation
 */
class fuse_fs_entry_dir : public fuse_fs_entry {
public:

private:

public:
	fuse_fs_entry_dir(string path, fuse_fs* fs);
	~fuse_fs_entry_dir();

	virtual int add_fs_entry(shared_fs_entry fe);
	virtual int get_dirent(off_t o, string& name, struct stat& st);

protected:

private:
};

}	// namespace flare
}	// namespace gree

#endif	// FUSE_FS_ENTRY_DIR_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
