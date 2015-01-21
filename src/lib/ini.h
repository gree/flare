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
 *	ini.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef INI_H
#define INI_H

#include <fstream>
#include <iostream>
#include <string>

#include <boost/program_options.hpp>

#include "config.h"
#include "singleton.h"
#include "logger.h"
#include "util.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	flared configuration base class
 */
class ini {
protected:
	bool			_load;
public:
	ini();
	virtual ~ini();

	virtual int load() = 0;
	virtual int reload() = 0;

	bool is_load() { return this->_load; };
};

}	// namespace flare
}	// namespace gree

#endif // INI_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
