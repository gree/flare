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
 *	op_flush_all.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_FLUSH_ALL_H
#define	OP_FLUSH_ALL_H

#include "op.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (flush_all)
 */
class op_flush_all : public op {
protected:
	// Administrative gate: when false the op is refused with SERVER_ERROR.
	// memcached has no authentication, so an exposed flared answers
	// flush_all from ANY client that can reach it — a one-line total data
	// wipe. The gate is pushed in by the parser from flared's
	// `flush-all-enabled` config (SIGHUP-hot-reloadable; in K8s mode
	// toggleable cluster-wide in seconds via the FlareCluster CRD).
	bool _flush_all_enabled = true;
public:
	void set_flush_all_enabled(bool b) { this->_flush_all_enabled = b; };
protected:
	storage*					_storage;
	int								_expire;
	int								_option;

public:
	op_flush_all(shared_connection c, storage* st);
	virtual ~op_flush_all();

	virtual int run_client(time_t expire, storage::option option);

protected:
	op_flush_all(shared_connection c, string ident, binary_header::opcode opcode, storage* st);
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(time_t expire, storage::option option);
	virtual int _parse_text_client_parameters(storage::option option);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_FLUSH_ALL_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
