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
 *	op_keys.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_KEYS_H
#define	OP_KEYS_H

#include "op_proxy_read.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (keys)
 */
class op_keys : public op_proxy_read {
protected:

public:
	op_keys(shared_connection c, cluster* cl, storage* st);
	virtual ~op_keys();

protected:
	int _parse_text_server_parameters();
	int _run_server();
	int _run_client(storage::entry&e, void* parameter);
	int _run_client(list<storage::entry>& e, void* parameter);
	int _parse_text_client_parameters(storage::entry& e);
	int _parse_text_client_parameters(list<storage::entry>& e);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_KEYS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
