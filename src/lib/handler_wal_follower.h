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
 *	handler_wal_follower.h
 *
 *	CONTINUOUS WAL REPLICATION, follower side (SAF-10b stage 3b).
 *
 *	Keeps pulling the master's WAL during normal operation and applies it
 *	through the common apply rule, so a replica that lost connectivity catches
 *	up by itself once the link returns — without a full reconstruction and
 *	without waiting for a new write to trigger anything.
 *
 *	What this handler must NEVER do, and what the tests pin:
 *	  - treat a lost connection as a repair trigger. A disconnect means
 *	    reconnect and resume FROM THE POSITION; only an explicit
 *	    needs_rebuild (history purged past our position, the source serving a
 *	    different history, a batch that cannot be decoded) hands the node to
 *	    the rebuild path (design §5.4);
 *	  - advance the applied position for anything it did not apply;
 *	  - keep asking a source that cannot identify its history.
 */
#ifndef	HANDLER_WAL_FOLLOWER_H
#define	HANDLER_WAL_FOLLOWER_H

#include <string>

#include "connection.h"
#include "thread_handler.h"
#include "cluster.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

class handler_wal_follower : public thread_handler {
public:
	// What one attempt at a slice produced. Separated from the transport so
	// the decision table below can be unit-tested without a socket.
	enum attempt_outcome {
		attempt_progress = 0,	// applied (or legitimately skipped) a slice
		attempt_idle,			// nothing new; stay connected
		attempt_disconnected,	// transport failed: retry, keep the data
		attempt_needs_rebuild,	// this position can never be satisfied again
		attempt_error,			// storage/protocol failure: retry
	};

	// The decision this handler makes for every client result. Pure, so the
	// "a disconnect is not a rebuild" rule is testable directly.
	static attempt_outcome classify(int client_result, bool transport_ok);
	static const char* reason_for(int client_result);

protected:
	cluster*			_cluster;
	storage*			_storage;
	shared_connection	_connection;
	const string		_source_name;
	const int			_source_port;
	const uint64_t		_max_batches;
	const uint64_t		_max_response_bytes;
	const int			_poll_interval_usec;

public:
	handler_wal_follower(shared_thread t, cluster* cl, storage* st,
		string source_name, int source_port,
		uint64_t max_batches, uint64_t max_response_bytes, int poll_interval_usec);
	virtual ~handler_wal_follower();

	virtual int run();

private:
	int _follow_once(bool& more);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_WAL_FOLLOWER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
