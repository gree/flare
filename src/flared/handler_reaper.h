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
 *	handler_reaper.h
 *
 *	background expire crawler (memcached lru_crawler equivalent)
 */
#ifndef	HANDLER_REAPER_H
#define	HANDLER_REAPER_H

#include "app.h"
#include "cluster.h"
#include "storage.h"

namespace gree {
namespace flare {

/**
 *	background thread that periodically sweeps the keyspace on the partition
 *	MASTER and physically deletes past-expire entries.
 *
 *	Why a thread that issues real deletes (rather than a RocksDB compaction
 *	filter): with WAL-based cluster replication a compaction-filter drop would
 *	bypass the WAL and never reach the slaves, diverging them. A real remove()
 *	on the master lands in the WAL and replicates. It therefore MUST run only on
 *	the master (a slave issuing its own deletes would advance its LSN
 *	independently and break WAL follow); slaves get the deletes via the WAL.
 */
class handler_reaper : public thread_handler {
protected:
	cluster*	_cluster;
	storage*	_storage;

public:
	handler_reaper(shared_thread t, cluster* cl, storage* st);
	virtual ~handler_reaper();

	virtual int run();

protected:
	bool _is_reap_target();
	bool _sleep_interruptible(int seconds);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_REAPER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
