/**
 *	coordinator_factory.h
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#ifndef	__COORDINATOR_FACTORY_H__
#define	__COORDINATOR_FACTORY_H__

#include "config.h"
#include "coordinator.h"

#include <stdio.h>

using namespace std;

namespace gree {
namespace flare {

class coordinator;

class coordinator_factory
{
#ifdef HAVE_LIBZOOKEEPER_MT
	FILE*		_log_stream;
#endif

public:
	coordinator_factory();
	virtual ~coordinator_factory();

public:
	coordinator* create_coordinator(const string& identifier, const string& myname);
	void destroy_coordinator(coordinator* coord);
};

}	// namespace flare
}	// namespace gree

#endif	// __COORDINATOR_FACTORY_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
