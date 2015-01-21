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
 *	op_getq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_GETQ_H
#define	OP_GETQ_H

#include "op_getq.h"

namespace gree {
namespace flare {

/**
 *	opcode class (GetQ)
 */
class op_getq : public op_get {
public:
	op_getq(shared_connection c, cluster* cl, storage* st):
		op_get(c, "get", binary_header::opcode_getq, cl, st) {
	}

	virtual ~op_getq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_GETQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
