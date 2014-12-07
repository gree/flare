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
 *	op_version.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_VERSION_H
#define	OP_VERSION_H

#include "op.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (version)
 */
class op_version: public op {
protected:

public:
	op_version(shared_connection c);
	virtual ~op_version();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();

private:
	inline int _send_version();
	int _send_text_version();
	int _send_binary_version();
};

int op_version::_send_version() {
	return _protocol == op::text
		? _send_text_version()
		: _send_binary_version();
}

}	// namespace flare
}	// namespace gree

#endif	// OP_VERSION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
