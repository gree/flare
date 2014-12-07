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
 *	op_replace.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_REPLACE_H
#define	OP_REPLACE_H

#include "op_set.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (replace)
 */
class op_replace : public op_set {
public:
	op_replace(shared_connection c, cluster* cl, storage* st);
	virtual ~op_replace();

protected:
	op_replace(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_REPLACE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
