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
 *	op_parser_binary_index.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef OP_PARSER_BINARY_INDEX_H
#define OP_PARSER_BINARY_INDEX_H

#include "op_parser_binary.h"

namespace gree {
namespace flare {

/**
 *	opcode binary parser for index application
 */
class op_parser_binary_index : public op_parser_binary {
protected:
	virtual op* _determine_op(const binary_request_header&) { return NULL; }

public:
	op_parser_binary_index(shared_connection c);
	virtual ~op_parser_binary_index();
};

}	// namespace flare
}	// namespace gree

#endif // OP_PARSER_BINARY_INDEX_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
