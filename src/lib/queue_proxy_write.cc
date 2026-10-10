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
 *	queue_proxy_write.cc
 *
 *	implementation of gree::flare::queue_proxy_write
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "queue_proxy_write.h"

#include <boost/lexical_cast.hpp>
#include "handler_proxy.h"
#include "app.h"
#include "connection_tcp.h"
#include "op_proxy_write.h"
#include "op_add.h"
#include "op_append.h"
#include "op_cas.h"
#include "op_decr.h"
#include "op_delete.h"
#include "op_incr.h"
#include "op_prepend.h"
#include "op_set.h"
#include "op_replace.h"
#include "op_touch.h"
#include "op_gat.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for queue_proxy_write
 */
queue_proxy_write::queue_proxy_write(cluster* cl, storage* st, vector<string> proxy, storage::entry entry, string op_ident):
		thread_queue("proxy_write"),
		_cluster(cl),
		_storage(st),
		_proxy(proxy),
		_entry(entry),
		_op_ident(op_ident),
		_result(op::result_none),
		_result_message(""),
		_post_proxy(false),
		_generic_value(0) {
}

/**
 *	dtor for queue_proxy_write
 */
queue_proxy_write::~queue_proxy_write() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int queue_proxy_write::run(shared_connection c) {
#ifdef DEBUG
	if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
		log_debug("proxy request (write) (host=%s, port=%d, op=%s, key=%s, version=%u)", ctp->get_host().c_str(), ctp->get_port(), this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
	}
#endif

	// FAIL FAST (forward-window-steps 38048708017): the destination's
	// connection is down and failed to open moments ago — count this forward
	// as dropped now (the repair path sees it) instead of queueing it behind
	// another bounded connect; a later forward tries to connect again.
	if (connection_tcp* fctp = dynamic_cast<connection_tcp*>(c.get())) {
		if (!fctp->is_available() && fctp->open_failed_within(handler_proxy::proxy_fail_fast_window_ms)) {
			char dest[BUFSIZ];
			snprintf(dest, sizeof(dest), "%s:%d", fctp->get_host().c_str(), fctp->get_port());
			if (!this->_post_proxy) {
				// a client write forwarded TO the master: the client hears the
				// failure (no replica fell behind, nothing to count)
				return -1;
			}
			stats_object->increment_proxy_write_dropped(string(dest));
			if (stats_object->diag_enabled()) {
				stats_object->diag_incr(string("fwd_dropped_fast:") + dest);
			}
			static AtomicCounter fast_logged(0);
			if (fast_logged.incr() % 100 == 1) {
				log_err("proxy write DROPPED at once (dest=%s, op=%s, key=%s, version=%u): the connection failed to open %d ms ago or less — counted; replica diverges until it is repaired (logged 1 in 100)",
						dest, this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version, handler_proxy::proxy_fail_fast_window_ms);
			}
			return -1;
		}
	}

	op_proxy_write* p = this->_get_op(this->_op_ident, c);
	if (p == NULL) {
		return -1;
	}
	p->set_proxy(this->_proxy);
	// SAF-10b stage 3: carry the source's replication identity with the
	// change, so the destination can order it against the same change
	// arriving through the WAL stream instead of overwriting blindly. The
	// label was captured inside the key's critical section when the master
	// wrote locally (design §3.9(B)); an empty epoch means the source cannot
	// identify its history, in which case nothing is sent and the receiver
	// behaves exactly as before.
	if (this->_cluster != NULL && this->_cluster->get_repl_identity_forward()
			&& this->_storage != NULL && this->_entry.seq_label > 0) {
		const string epoch = this->_storage->get_source_epoch();
		if (!epoch.empty()) {
			this->_entry.repl_tag = epoch + "/" + boost::lexical_cast<string>(this->_entry.seq_label);
		}
	}

	int retry = queue_proxy_write::max_retry;
	while (retry > 0) {
		if (p->run_client(this->_entry) >= 0) {
			break;
		}
		if (c->is_available() == false) {
#ifdef DEBUG
			if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
				log_debug("reconnecting (host=%s, port=%d)", ctp->get_host().c_str(), ctp->get_port());
			}
#endif
			c->open();
		}
		retry--;
	}
	if (retry <= 0) {
		// GIVING UP on a replica write. Nothing above us looks at this return
		// value (thread::run() ignores it) and the client was already told
		// STORED by the master, so the op is now silently missing on that
		// replica until its next reconstruction. Make it loud and countable —
		// this used to be completely invisible.
		if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
			log_err("proxy write DROPPED after %d retries (dest=%s:%d, op=%s, key=%s, version=%u): replica now diverges until it reconstructs",
					queue_proxy_write::max_retry, ctp->get_host().c_str(), ctp->get_port(),
					this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
			// Attribute it: a controller needs to know WHICH replica fell
			// behind so it can resync that one instead of guessing.
			char dest[BUFSIZ];
			snprintf(dest, sizeof(dest), "%s:%d", ctp->get_host().c_str(), ctp->get_port());
			stats_object->increment_proxy_write_dropped(string(dest));
		} else {
			log_err("proxy write DROPPED after %d retries (op=%s, key=%s, version=%u): replica now diverges until it reconstructs",
					queue_proxy_write::max_retry, this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version);
			stats_object->increment_proxy_write_dropped();
		}
		delete p;
		return -1;
	}

	this->_success = true;
	this->_result = p->get_result();
	if (stats_object->diag_enabled() && this->_post_proxy) {
		if (const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get())) {
			stats_object->diag_incr("fwd_answered:" + ctp->get_host() + ":" + boost::lexical_cast<string>(ctp->get_port())
				+ ":" + boost::lexical_cast<string>(static_cast<int>(this->_result)));
		}
	}
	// DIAGNOSTIC (copy-identity 11, manual run 37899958227: 10 forwarded writes
	// acknowledged by the master never reached a replica, with no drop logged
	// or counted): the replica ANSWERED, but not with a success — its answer
	// was ignored here. Logged (rate-limited) with the destination; no change
	// of behaviour (whether such an answer is a drop is not decided yet).
	if (this->_result != op::result_stored && this->_result != op::result_deleted
			&& this->_result != op::result_touched && this->_result != op::result_ok
			&& this->_result != op::result_not_found) {
		static AtomicCounter unexpected_logged(0);
		if (unexpected_logged.incr() % 100 == 1) {
			const connection_tcp* ctp = dynamic_cast<const connection_tcp*>(c.get());
			log_warning("proxy write ANSWERED but not stored by the replica (dest=%s:%d, op=%s, key=%s, version=%u, result=%s) — the replica may now miss this write (logged 1 in 100)",
				ctp ? ctp->get_host().c_str() : "?", ctp ? ctp->get_port() : 0,
				this->_op_ident.c_str(), this->_entry.key.c_str(), this->_entry.version,
				op::result_cast(this->_result).c_str());
		}
	}
	// :(
	log_debug("result: %s:%d", p->get_ident().c_str(), this->_result);
	if ((p->get_ident() == "incr" || p->get_ident() == "decr") && this->_result == op::result_stored) {
		log_debug("available: %d", this->_entry.is_data_available());
		if (this->_entry.is_data_available()) {
			char buf[BUFSIZ];
			memcpy(buf, this->_entry.data.get(), this->_entry.size);
			snprintf(buf+this->_entry.size, sizeof(buf)-this->_entry.size, "%s", line_delimiter);
			this->_result_message = buf;
		} else {
			this->_result_message = p->get_result_message();
		}
	} else {
		this->_result_message = p->get_result_message();
	}
	delete p;

	return 0;
}
// }}}

// {{{ protected methods
op_proxy_write* queue_proxy_write::_get_op(string op_ident, shared_connection c) {
	if (op_ident == "set") {
		return new op_set(c, this->_cluster, this->_storage);
	} else if (op_ident == "add") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_add(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "replace") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_replace(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "cas") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_cas(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "append") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_append(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "prepend") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			return new op_prepend(c, this->_cluster, this->_storage);
		}
	} else if (op_ident == "incr") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			op_incr* p = new op_incr(c, this->_cluster, this->_storage);
			p->set_value(this->_generic_value);
			return p;
		}
	} else if (op_ident == "decr") {
		if (this->is_post_proxy()) {
			return new op_set(c, this->_cluster, this->_storage);
		} else {
			op_incr* p = new op_decr(c, this->_cluster, this->_storage);
			p->set_value(this->_generic_value);
			return p;
		}
	} else if (op_ident == "delete") {
		return new op_delete(c, this->_cluster, this->_storage);
	} else if (op_ident == "touch") {
		return new op_touch(c, this->_cluster, this->_storage);
	} else if (op_ident == "gat") {
		if (this->is_post_proxy()) {
			return new op_touch(c, this->_cluster, this->_storage);
		} else {
			return new op_gat(c, this->_cluster, this->_storage);
		}
	}
	log_warning("unknown op (ident=%s)", op_ident.c_str());

	return NULL;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
