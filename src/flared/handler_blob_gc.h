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
 *	handler_blob_gc.h
 *
 *	background compaction of SSTs whose blob files are mostly garbage
 */
#ifndef	HANDLER_BLOB_GC_H
#define	HANDLER_BLOB_GC_H

#include "app.h"
#include "storage.h"

namespace gree {
namespace flare {

/**
 *	Reclaims the blob garbage RocksDB's own GC leaves behind
 *	(storage_rocksdb::blob_gc_compact_step). Every
 *	`rocksdb-blob-compact-interval` seconds (0 = off) it checks the blob
 *	files. When their garbage is at least `rocksdb-blob-compact-percent` of
 *	them and at least `rocksdb-blob-compact-min-mb`, it makes one pass:
 *	every SST that references a blob file is compacted once, one at a time,
 *	`rocksdb-blob-compact-pause-ms` apart. Then it waits for the next
 *	interval. All four are re-read on every check (SIGHUP); interval 0 also
 *	stops a pass between two steps.
 */
class handler_blob_gc : public thread_handler {
protected:
	storage*	_storage;

public:
	handler_blob_gc(shared_thread t, storage* st);
	virtual ~handler_blob_gc();

	virtual int run();

protected:
	bool _sleep_interruptible_ms(int msec);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_BLOB_GC_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
