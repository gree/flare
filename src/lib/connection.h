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
 *	connection.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef CONNECTION_H
#define CONNECTION_H

#include <string>

#include <boost/shared_ptr.hpp>

using std::string;

namespace gree {
namespace flare {

typedef class connection connection;
typedef boost::shared_ptr<connection> shared_connection;

/**
 *	network connection class
 */
class connection {
public:
	connection() { }
	virtual ~connection() { }

	virtual int open() = 0;
	virtual int close() = 0;
	virtual bool is_available() const = 0;

	virtual int read(char** p, int expect_len, bool readline, bool& actual) = 0;
	virtual int readline(char** p) = 0;
	virtual int readsize(int expect_len, char** p) = 0;
	virtual int push_back(const char* p, int bufsiz) = 0;
	virtual int write(const char *p, int bufsiz, bool buffered = false) = 0;
	virtual int writeline(const char* p) = 0;
};

}	// namespace flare
}	// namespace gree

#endif // CONNECTION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
