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
