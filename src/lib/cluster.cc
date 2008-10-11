/**
 *	cluster.cc
 *
 *	implementation of gree::flare::cluster
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "cluster.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for cluster
 */
cluster::cluster(thread_pool* tp):
		_thread_pool(tp) {
}

/**
 *	dtor for cluster
 */
cluster::~cluster() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	startup proc for index process
 */
int cluster::startup_index() {
	return 0;
}

/**
 *	startup proc for node process
 */
int cluster::startup_node() {
	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
