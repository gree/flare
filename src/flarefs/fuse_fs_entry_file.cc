/**
 *	fuse_fs_entry_file.cc
 *
 *	implementation of gree::flare::fuse_fs_entry_file
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "fuse_fs_entry_file.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for fuse_fs_entry_file
 */
fuse_fs_entry_file::fuse_fs_entry_file(string path, fuse_fs* fs):
		fuse_fs_entry(path, fs) {
	this->_type = type_file;
}

/**
 *	dtor for fuse_fs_entry_file
 */
fuse_fs_entry_file::~fuse_fs_entry_file() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
