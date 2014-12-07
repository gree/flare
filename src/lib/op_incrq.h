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
 *	op_incrq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_INCRQ_H
#define	OP_INCRQ_H

#include "op_incr.h"

namespace gree {
namespace flare {

/**
 *	opcode class (IncrQ)
 */
class op_incrq : public op_incr {
public:
	op_incrq(shared_connection c, cluster* cl, storage* st):
		op_incr(c, "incr", binary_header::opcode_incrementq, cl, st) {
	}

	virtual ~op_incrq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_INCRQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
