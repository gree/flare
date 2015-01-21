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
