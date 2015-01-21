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
 *	key_resolver_modular.cc
 *
 *	implementation of gree::flare::key_resolver_modular
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "key_resolver_modular.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for key_resolver_modular
 */
key_resolver_modular::key_resolver_modular(int p, int hint, int v):
		_partition_size(p),
		_hint(hint),
		_virtual(v),
		_map(NULL) {
}

/**
 *	dtor for key_resolver_modular
 */
key_resolver_modular::~key_resolver_modular() {
	if (this->_map != NULL) {
		for (int i = 0; i < this->_partition_size; i++) {
			delete[] this->_map[i];
			this->_map[i] = NULL;
		}
		delete[] this->_map;
		this->_map = NULL;
	}
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	key resolver startup procs
 */
int key_resolver_modular::startup() {
	this->_map = new int*[this->_partition_size];

	log_debug("building key resolving table (type=modular)...", 0);
	for (int i = 0; i < this->_partition_size; i++) {
		if (i == 0) {
			this->_map[i] = NULL;
			continue;
		}

		this->_map[i] = new int[this->_virtual];
		int counter[this->_partition_size];
		memset(counter, 0, sizeof(counter));

		for (int j = 0; j < this->_virtual; j++) {
			if (i <= this->_hint) {
				this->_map[i][j] = j % i;
				continue;
			}

			int k = this->_map[i-1][j];
			counter[k]++;
			if ((counter[k] % i) == (i - 1)) {
				this->_map[i][j] = i - 1;
			} else {
				this->_map[i][j] = this->_map[i-1][j];
			}
		}
	}
	log_debug("ok (max_partition_size=%d, virtual_node_size=%d)", this->_partition_size, this->_virtual);

	return 0;
}

/**
 *	get partition for key hash value
 */
int key_resolver_modular::resolve(int key_hash_value, int partition_size) {
	// XXX: check partition_size is smaller than this->_partition_size
	return this->_map[partition_size][key_hash_value % this->_virtual];
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
