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
 *	op_quitq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_QUITQ_H
#define	OP_QUITQ_H

#include "op_quit.h"

namespace gree {
namespace flare {

/**
 *	opcode class (QuitQ)
 */
class op_quitq : public op_quit {
public:
	op_quitq(shared_connection c):
		op_quit(c, "quit", binary_header::opcode_quitq) {
	}

	virtual ~op_quitq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_QUITQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
