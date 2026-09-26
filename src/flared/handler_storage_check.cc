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
 *	handler_storage_check.cc
 *
 *	implementation of gree::flare::handler_storage_check
 */
#include "handler_storage_check.h"
#include "ini_option.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

#include <unistd.h>

namespace gree {
namespace flare {

// {{{ ctor/dtor
handler_storage_check::handler_storage_check(shared_thread t, cluster* cl, storage* st):
		thread_handler(t),
		_cluster(cl),
		_storage(st) {
}

handler_storage_check::~handler_storage_check() {
}
// }}}

// {{{ public methods
int handler_storage_check::run() {
	this->_thread->set_state("wait");
	this->_thread->set_op("");

	for (;;) {
		// Re-read the interval each cycle so a SIGHUP takes effect; sleep in
		// 1s steps so shutdown stays responsive.
		int interval = ini_option_object().get_storage_check_interval();
		if (interval < 1) {
			// disabled — poll the flag cheaply so a SIGHUP that ENABLES it is
			// picked up within a minute.
			if (!this->_sleep_interruptible(60)) {
				this->_thread->set_state("shutdown");
				break;
			}
			continue;
		}
		if (!this->_sleep_interruptible(interval)) {
			this->_thread->set_state("shutdown");
			break;
		}

#ifdef HAVE_LIBROCKSDB
		if (this->_storage == NULL || this->_storage->get_type() != storage::type_rocksdb) {
			continue;
		}
		storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
		if (rdb == NULL) {
			continue;
		}
		if (rdb->is_corrupted()) {
			continue;	// already latched; nothing to re-verify until recovery
		}

		this->_thread->set_state("execute");
		this->_thread->set_op("storage_check");
		if (rdb->verify_integrity() < 0) {
			// verify_integrity already latched + logged. Recovery is owned by
			// reconstruction (slave self-heal) / the operator (drives a
			// steady-state corrupt slave into reconstruction; alerts on a
			// master). We only surface the signal here.
			log_err("periodic storage check FAILED -> rocksdb_corrupted latched; expect operator-driven reseed (slave) or alert (master)", 0);
		} else {
			log_debug("periodic storage check passed", 0);
		}
		this->_thread->set_state("wait");
		this->_thread->set_op("");
#endif
	}

	return 0;
}
// }}}

// {{{ protected methods
bool handler_storage_check::_sleep_interruptible(int seconds) {
	for (int i = 0; i < seconds; i++) {
		if (this->_thread->is_shutdown_request()) {
			return false;
		}
		sleep(1);
	}
	return !this->_thread->is_shutdown_request();
}
// }}}

}	// namespace flare
}	// namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
