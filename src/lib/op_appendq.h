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
 *	op_appendq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_APPENDQ_H
#define	OP_APPENDQ_H

#include "op_append.h"

namespace gree {
namespace flare {

/**
 *	opcode class (AppendQ)
 */
class op_appendq : public op_append {
public:
	op_appendq(shared_connection c, cluster* cl, storage* st):
		op_append(c, "append", binary_header::opcode_appendq, cl, st) {
	}

	virtual ~op_appendq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_APPENDQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
