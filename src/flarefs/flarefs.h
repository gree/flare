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
 *	flarefs.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	FLAREFS_H
#define	FLAREFS_H

#define	FUSE_USE_VERSION	25
#include <fuse.h>

#include "app.h"
#include "ini_option.h"

namespace gree {
namespace flare {

typedef class fuse_impl fuse_impl;

/**
 *	flarefs application class
 */
class flarefs : public app {
private:
	fuse_impl*				_fuse;

public:
	flarefs();
	~flarefs();

	int startup(int argc, char** argv);
	int run();
	int reload();
	int shutdown();

protected:
	string _get_pid_path();

private:
	int _set_resource_limit();
	int _set_signal_handler();
};

}	// namespace flare
}	// namespace gree

#endif	// FLAREFS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
