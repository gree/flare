/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 */
/**
 *	op_orphan_purge.h
 *
 *	Destructive counterpart to `orphan_scan`. Requires a token issued
 *	by a preceding scan and refuses to run if topology has changed
 *	since that scan. Never touches reserved replication metadata keys
 *	(those are protected at the storage layer regardless). See
 *	ROCKSDB_REPLICATION.md for rationale.
 *
 *	syntax:
 *	    orphan_purge <token>
 */
#ifndef	OP_ORPHAN_PURGE_H
#define	OP_ORPHAN_PURGE_H

#include "op.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

class op_orphan_purge : public op {
protected:
	cluster*	_cluster;
	storage*	_storage;
	string		_token;

public:
	op_orphan_purge(shared_connection c, cluster* cl, storage* st);
	virtual ~op_orphan_purge();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_ORPHAN_PURGE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
