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
 *	op_quit.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_QUIT_H
#define	OP_QUIT_H

#include "op.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (quit)
 */
class op_quit : public op {
public:
	op_quit(shared_connection c);
	virtual ~op_quit();

protected:
	op_quit(shared_connection c, string ident, binary_header::opcode opcode);
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual inline int _send_text_result(result r, const char* message = NULL);
};

int op_quit::_send_text_result(result r, const char* message) {
	return 0;
}

}	// namespace flare
}	// namespace gree

#endif	// OP_QUIT_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
