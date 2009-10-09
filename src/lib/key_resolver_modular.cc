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
key_resolver_modular::key_resolver_modular(int hint):
		_hint(hint),
		_map(NULL) {
}

/**
 *	dtor for key_resolver_modular
 */
key_resolver_modular::~key_resolver_modular() {
	if (this->_map != NULL) {
		for (int i = 0; i < cluster::max_partition_size; i++) {
			if (this->_map[i] != NULL) {
				_delete_(this->_map[i]);
			}
		}
		_delete_(this->_map);
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
	this->_map = _new_ int*[cluster::max_partition_size];

	log_debug("buiding key resolving table (type=modular)...", 0);
	for (int i = 0; i < cluster::max_partition_size; i++) {
		if (i == 0) {
			this->_map[i] = NULL;
			continue;
		}

		this->_map[i] = _new_ int[key_resolver_modular::key_distribution_size];
		int counter[cluster::max_partition_size];
		memset(counter, 0, sizeof(counter));

		for (int j = 0; j < key_resolver_modular::key_distribution_size; j++) {
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
	log_debug("ok (max_partition_size=%d, key_distribution_size=%d)", cluster::max_partition_size, key_resolver_modular::key_distribution_size);

	return 0;
}

/**
 *	get partition for key hash value
 */
int key_resolver_modular::resolve(int key_hash_value, int partition_size) {
	// XXX: check partition_size is smaller than cluster::max_partition_size
	return this->_map[partition_size][key_hash_value % key_resolver_modular::key_distribution_size];
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
