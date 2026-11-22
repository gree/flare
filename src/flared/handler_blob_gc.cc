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
 *	handler_blob_gc.cc
 *
 *	implementation of gree::flare::handler_blob_gc
 */
#include "handler_blob_gc.h"
#include "ini_option.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

#include <unistd.h>

namespace gree {
namespace flare {

// {{{ ctor/dtor
handler_blob_gc::handler_blob_gc(shared_thread t, storage* st):
		thread_handler(t),
		_storage(st) {
}

handler_blob_gc::~handler_blob_gc() {
}
// }}}

// {{{ public methods
int handler_blob_gc::run() {
	this->_thread->set_state("wait");
	this->_thread->set_op("");

	for (;;) {
		int interval = ini_option_object().get_rocksdb_blob_compact_interval();
		// disabled: look again in a minute so a SIGHUP that enables it is
		// picked up
		if (!this->_sleep_interruptible_ms((interval < 1 ? 60 : interval) * 1000)) {
			break;
		}
		if (interval < 1) {
			continue;
		}

#ifdef HAVE_LIBROCKSDB
		if (this->_storage == NULL || this->_storage->get_type() != storage::type_rocksdb) {
			continue;
		}
		storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
		if (rdb == NULL) {
			continue;
		}
		this->_thread->set_state("execute");
		this->_thread->set_op("blob_gc");
		// The thresholds start a pass; the pass then compacts every SST that
		// references a blob file once (stopping at the threshold would leave
		// it just below: half the blob bytes garbage at the default 50%).
		const double ratio = ini_option_object().get_rocksdb_blob_compact_percent() / 100.0;
		const uint64_t min_bytes = static_cast<uint64_t>(ini_option_object().get_rocksdb_blob_compact_min_mb()) * 1024 * 1024;
		const int min_free = ini_option_object().get_rocksdb_blob_compact_min_free_percent();
		const int pass = rdb->blob_referencing_ssts();
		// A step answers 1 (compacted), 0 (nothing to do), -1 (failed,
		// counted), 2 (another compaction was in the way: nothing done, try
		// again after the pause; a pass gives up after busy_limit in a row)
		// or 3 (the step's largest possible output would leave less than the
		// free floor: the pass ends, a later check tries again, after a
		// backup has let go of the old files).
		int r = rdb->blob_gc_compact_step(ratio, min_bytes, min_free);
		int done = r == 1 ? 1 : 0;
		int busy = r == 2 ? 1 : 0;
		while ((r == 1 || r == 2) && done < pass && busy < busy_limit) {
			if (!this->_sleep_interruptible_ms(ini_option_object().get_rocksdb_blob_compact_pause_ms())) {
				break;
			}
			// a SIGHUP can stop it between two steps
			if (ini_option_object().get_rocksdb_blob_compact_interval() < 1) {
				break;
			}
			r = rdb->blob_gc_compact_step(0.0, 0, min_free);
			if (r == 1) {
				done++;
				busy = 0;
			} else if (r == 2) {
				busy++;
			}
		}
		this->_thread->set_state("wait");
		this->_thread->set_op("");
#endif
	}

	this->_thread->set_state("shutdown");
	return 0;
}
// }}}

// {{{ protected methods
bool handler_blob_gc::_sleep_interruptible_ms(int msec) {
	// 100 ms steps so shutdown stays responsive
	for (int left = msec; left > 0; left -= 100) {
		if (this->_thread->is_shutdown_request()) {
			return false;
		}
		usleep((left < 100 ? left : 100) * 1000);
	}
	return !this->_thread->is_shutdown_request();
}
// }}}

}	// namespace flare
}	// namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
