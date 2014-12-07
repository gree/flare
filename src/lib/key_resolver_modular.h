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
 *	key_resolver_modular.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	KEY_RESOLVER_MODULAR_H
#define	KEY_RESOLVER_MODULAR_H

#include "key_resolver.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	partition key resolver class (modular)
 */
class key_resolver_modular : public key_resolver {
public:

protected:
	static const type		_type = key_resolver::type_modular;

	int									_partition_size;
	int									_hint;
	int									_virtual;
	int**								_map;

public:
	key_resolver_modular(int p, int hint, int v);
	virtual ~key_resolver_modular();

	int startup();
	type get_type() { return this->_type; };
	int get_partition_size() { return this->_partition_size; };
	int get_hint() { return this->_hint; };
	int get_virtual() { return this->_virtual; };
	int resolve(int key_hash_value, int partition_size);
};

}	// namespace flare
}	// namespace gree

#endif	// KEY_RESOLVER_MODULAR_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
