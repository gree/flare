/**
 *	fuse_fs_entry_dir.cc
 *
 *	implementation of gree::flare::fuse_fs_entry_dir
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "fuse_fs_entry_dir.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for fuse_fs_entry_dir
 */
fuse_fs_entry_dir::fuse_fs_entry_dir(string path, fuse_fs* fs):
		fuse_fs_entry(path, fs) {
	this->_type = type_dir;
}

/**
 *	dtor for fuse_fs_entry_dir
 */
fuse_fs_entry_dir::~fuse_fs_entry_dir() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	add new fs entry
 */
int fuse_fs_entry_dir::add_fs_entry(shared_fs_entry fe) {
	vector<string> fe_list;
	if (this->_get_fs_entry_list(fe_list) < 0) {
		return -1;
	}
	fe_list.push_back(fe->get_file_name());

	return 0;
}

/**
 *	get_dirent
 */
int fuse_fs_entry_dir::get_dirent(off_t o, string& name, struct stat& st) {
	string path = "";
	shared_fs_entry fe;

	log_debug("retrieving directory entry (offset=%d)", o);

	if (o == 0) {
		name = ".";
		st = this->get_stat();
		return 0;
	} else if (o == 1) {
		name = "..";
		if (this->get_parent(fe) < 0) {
			log_warning("failed to get parent fs entry object (path=%s, offset=%d)", this->_path.c_str(), o);
			return -1;
		}
		st = fe->get_stat();
		// XXX
		return 0;
	}

	// XXX
	name = "";
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
