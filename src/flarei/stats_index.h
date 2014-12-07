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
 *	stats_index.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef STATS_INDEX_H
#define STATS_INDEX_H

#include "stats.h"

namespace gree {
namespace flare {

/**
 *	stats class for flarei
 */
class stats_index : public stats {
protected:

public:
	stats_index();
	virtual ~stats_index();
	virtual uint32_t get_curr_connections(thread_pool* tp);
};

}	// namespace flare
}	// namespace gree

#endif // STATS_INDEX_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
