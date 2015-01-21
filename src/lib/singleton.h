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
 *	singleton.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	SINGLETON_H
#define	SINGLETON_H

namespace gree {
namespace flare {

/**
 *	template class to add singleton feature
 */
template <class T>
class singleton {
private:
	singleton();
	singleton(singleton const&);
	singleton& operator=(singleton const&);
	virtual ~singleton();

public:
	static T& instance() {
		static T obj;
		return obj;
	};
};

}	// namespace flare
}	// namespace gree

#endif	// SINGLETON_H
// vim: foldmethod=marker tabstop=4 shiftwidth=4 autoindent
