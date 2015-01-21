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
 *	op_show_index.h
 *
 *	@author	Takanori Sejima <takanori.sejima@gmail.com>
 *
 *	$Id$
 */
#ifndef OP_SHOW_INDEX_H
#define OP_SHOW_INDEX_H

#include <sstream>

#include "op_show.h"

namespace gree {
namespace flare {

/**
 *	opcode class (show)
 */
class op_show_index : public op_show {
protected:

public:
	op_show_index(shared_connection c);
	virtual ~op_show_index();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();

	virtual int _send_show_variables();
};

}	// namespace flare
}	// namespace gree

#endif // OP_SHOW_INDEX_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
