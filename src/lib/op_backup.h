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
 *	op_backup.h
 *
 *	Take a named, consistent on-disk backup (RocksDB Checkpoint) of the
 *	local storage. This protects against LOGICAL destruction (an errant
 *	flush_all, a bad migration, an operator mistake) that replication
 *	would faithfully propagate to every replica. The backup is a complete
 *	RocksDB directory an operator can restore by swapping it in for the
 *	live DB. Retention (how many backups to keep) is bounded by the
 *	storage's rocksdb-backup-keep setting.
 *
 *	Syntax:
 *	backup <name>
 *
 *	<name> is restricted to [A-Za-z0-9._-] (no leading '.', no '/') and
 *	is expected to be a sortable, timestamp-prefixed identifier so that
 *	retention pruning (lexical order) matches chronological order.
 *
 *	rocksdb storage only; other backends respond not_supported.
 */
#ifndef	OP_BACKUP_H
#define	OP_BACKUP_H

#include "op.h"

using namespace std;

namespace gree {
namespace flare {

class op_backup : public op {
protected:
	storage*	_storage;
	string		_backup_name;

public:
	op_backup(shared_connection c, storage* st);
	virtual ~op_backup();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_BACKUP_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
