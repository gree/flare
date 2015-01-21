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
 *	show_node.h
 *
 *	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
 *
 *	$Id$
 */
#ifndef SHOW_NODE_H
#define SHOW_NODE_H

#include <vector>
#include <string>

using namespace std;

namespace gree {
namespace flare {

class show_node {
public:
	static vector<string> lines();

protected:
	static string index_servers_line();
};

}	// namespace flare
}	// namespace gree

#endif // SHOW_NODE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
