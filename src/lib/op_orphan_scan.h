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
 */
/**
 *	op_orphan_scan.h
 *
 *	Read-only scan for "orphan" keys: keys present in this node's
 *	local storage that, under the current key_resolver + partition map,
 *	would be resolved to some OTHER partition. Orphans accumulate over
 *	zombie-master resurrection and split-brain recovery windows (see
 *	ROCKSDB_REPLICATION.md S4). This scan emits counts and a
 *	confirmation token that a subsequent `orphan_purge` op must quote
 *	back in order to actually delete them.
 *
 *	The scan never mutates storage. It is safe to run periodically for
 *	monitoring.
 */
#ifndef	OP_ORPHAN_SCAN_H
#define	OP_ORPHAN_SCAN_H

#include "op.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

class op_orphan_scan : public op {
protected:
	cluster*	_cluster;
	storage*	_storage;

public:
	op_orphan_scan(shared_connection c, cluster* cl, storage* st);
	virtual ~op_orphan_scan();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_ORPHAN_SCAN_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
