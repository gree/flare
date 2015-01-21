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
 *	key_resolver.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	KEY_RESOLVER_H
#define	KEY_RESOLVER_H

#include "logger.h"
#include "util.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	partition key resolver class
 */
class key_resolver {
public:
	enum									type {
		type_modular,
	};

protected:

public:
	key_resolver();
	virtual ~key_resolver();

	virtual int startup() = 0;
	virtual type get_type() = 0;
	virtual int resolve(int key_hash_value, int partition_size) = 0;

	static inline int type_cast(string s, type& t) {
		if (s == "modular") {
			t = type_modular;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string type_cast(type t) {
		switch (t) {
		case type_modular:
			return "modular";
		}
		return "";
	};
};

}	// namespace flare
}	// namespace gree

#endif	// KEY_RESOLVER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
