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
 *	op_prepend.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_PREPEND_H
#define	OP_PREPEND_H

#include "op_append.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (prepend)
 */
class op_prepend : public op_append {
public:
	op_prepend(shared_connection c, cluster* cl, storage* st);
	virtual ~op_prepend();

protected:
	op_prepend(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PREPEND_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
