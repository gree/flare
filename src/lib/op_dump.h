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
 *	op_dump.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_DUMP_H
#define	OP_DUMP_H

#include "op.h"
#include "cluster.h"
#include "storage.h"
#include "bwlimitter.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (dump)
 */
class op_dump : public op {
protected:
	cluster*					_cluster;
	storage*					_storage;
	int								_wait;
	int								_partition;
	int								_partition_size;
	bwlimitter				_bwlimitter;

public:
	op_dump(shared_connection c, cluster* cl, storage* st);
	virtual ~op_dump();

	virtual int run_client(int wait, int partition, int partition_size, uint64_t bwlimit = 0);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(int wait, int partition, int partition_size, uint64_t bwlimit);
	virtual int _parse_text_client_parameters();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_DUMP_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
