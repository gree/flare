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
 *	op_gat.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_GAT_H
#define	OP_GAT_H

#include "op_touch.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (gat)
 */
class op_gat : public op_touch {
public:
	op_gat(shared_connection c, cluster* cl, storage* st);
	virtual ~op_gat();

protected:
	op_gat(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	
	virtual int _parse_text_client_parameters(storage::entry& e);
	virtual int _send_text_result(result r, const char* message = NULL);
	virtual int _send_binary_result(result r, const char* message = NULL);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_GAT_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
