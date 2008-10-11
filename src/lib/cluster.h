/**
 *	cluster.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__CLUSTER_H__
#define	__CLUSTER_H__

#include "boost/regex.hpp"

#include "thread_pool.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	cluster class
 */
class cluster {
protected:
	thread_pool*			_thread_pool;

public:
	cluster(thread_pool* tp);
	virtual ~cluster();

	int startup_index();
	int startup_node();
};

}	// namespace flare
}	// namespace gree

#endif	// __CLUSTER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
