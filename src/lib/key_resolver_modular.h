/**
 *	key_resolver_modular.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__KEY_RESOLVER_MODULAR_H__
#define	__KEY_RESOLVER_MODULAR_H__

#include "key_resolver.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	partition key resolver class (modular)
 */
class key_resolver_modular : public key_resolver {
public:
	static const int		key_distribution_size = 4096;

protected:
	static const type		_type = key_resolver::type_modular;

	int									_hint;
	int**								_map;

public:
	key_resolver_modular(int hint);
	virtual ~key_resolver_modular();

	int startup();
	type get_type() { return this->_type; };
	int get_hint() { return this->_hint; };
	int resolve(int key_hash_value, int partition_size);
};

}	// namespace flare
}	// namespace gree

#endif	// __KEY_RESOLVER_MODULAR_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
