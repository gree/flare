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
 *	op_flush_allq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_FLUSH_ALLQ_H
#define	OP_FLUSH_ALLQ_H

#include "op_flush_all.h"

namespace gree {
namespace flare {

/**
 *	opcode class (FlushQ)
 */
class op_flush_allq : public op_flush_all {
public:
	op_flush_allq(shared_connection c, storage* st):
		op_flush_all(c, "flush_all", binary_header::opcode_flushq, st) {
	}

	virtual ~op_flush_allq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_FLUSH_ALLQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
