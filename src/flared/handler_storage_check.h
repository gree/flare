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
 *	handler_storage_check.h
 *
 *	background storage integrity verifier (opt-in)
 */
#ifndef	HANDLER_STORAGE_CHECK_H
#define	HANDLER_STORAGE_CHECK_H

#include "app.h"
#include "cluster.h"
#include "storage.h"

namespace gree {
namespace flare {

/**
 *	Periodically runs the storage's full checksum verification so on-disk
 *	corruption is caught PROACTIVELY (a stat the operator can alert on),
 *	rather than only when a client write happens to hit a poisoned SST and
 *	fails. Opt-in via `storage-check-interval` (0 = disabled): VerifyChecksum
 *	reads every SST/blob file, so it is deliberately not on by default.
 *
 *	It only LATCHES corruption (storage_rocksdb::verify_integrity increments
 *	the counter + sets the corrupted flag). Recovery stays with the
 *	established owners: a corrupt SLAVE self-heals via hard_reset on its next
 *	reconstruction (handler_reconstruction), and the operator drives a
 *	steady-state corrupt Active slave into that reconstruction off the
 *	`rocksdb_corrupted` stat; a corrupt MASTER is alerted on, never
 *	auto-wiped (its data may be the last surviving copy).
 */
class handler_storage_check : public thread_handler {
protected:
	cluster*	_cluster;
	storage*	_storage;

public:
	handler_storage_check(shared_thread t, cluster* cl, storage* st);
	virtual ~handler_storage_check();

	virtual int run();

protected:
	bool _sleep_interruptible(int seconds);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_STORAGE_CHECK_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
