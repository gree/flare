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
 *	op_repl_sync_wal.cc
 *
 *	implementation of gree::flare::op_repl_sync_wal
 *
 *	$Id$
 */
#include "op_repl_sync_wal.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_repl_sync_wal
 */
op_repl_sync_wal::op_repl_sync_wal(shared_connection c, storage* st):
		op(c, "repl_sync_wal"),
		_storage(st),
		_lsn(0),
		_client_master_id(""),
		_server_master_id(""),
		_client_result(client_server_error),
		_max_batch_bytes(0),
		_bwlimit_kbps(0),
		_interval_usec(0) {
}

/**
 *	dtor for op_repl_sync_wal
 */
op_repl_sync_wal::~op_repl_sync_wal() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_repl_sync_wal::run_client(uint64_t lsn, const string& master_id) {
	// Send the request, THEN read and apply the streamed WAL response.
	// Without the second step the master streams LSN/BATCH/.../END into a
	// connection the slave never reads: _client_result stays at its ctor
	// default (client_server_error), the caller sees a generic error and
	// falls back to a full dump every time, and wal_sync_success can never
	// increment. (Every other client op wires run_client the same way; see
	// op::run_client -> _parse_client_parameters.)
	if (this->_run_client(lsn, master_id) < 0) {
		return -1;
	}
	return this->_parse_text_client_parameters();
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 *
 *	syntax:
 *	REPL_SYNC_WAL <lsn> <master_id>
 *
 *	<master_id> is either a UUID the slave remembers from the last sync
 *	or "-" meaning "I have no prior lineage (fresh slave)".
 */
int op_repl_sync_wal::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	int n = util::next_digit(p, q, sizeof(q));
	if (q[0] == '\0') {
		log_warning("no LSN specified", 0);
		delete[] p;
		return -1;
	}

	try {
		this->_lsn = boost::lexical_cast<uint64_t>(q);
	} catch (boost::bad_lexical_cast e) {
		log_warning("invalid LSN [%s]", q);
		delete[] p;
		return -1;
	}

	// master_id token — missing ("") is accepted for backward
	// compatibility with pre-token clients; "-" explicitly means "no
	// prior lineage".
	n += util::next_word(p+n, q, sizeof(q));
	if (q[0] != '\0' && strcmp(q, "-") != 0) {
		this->_client_master_id = q;
	}
	log_debug("repl_sync_wal: lsn=%llu master_id=%s",
		this->_lsn, this->_client_master_id.c_str());

	// Check for extra parameters
	n += util::next_word(p+n, q, sizeof(q));
	if (q[0] != '\0') {
		log_notice("bogus parameter: %s -> ignoring", q);
	}

	delete[] p;
	return 0;
}

int op_repl_sync_wal::_run_server() {
#ifdef HAVE_LIBROCKSDB
	// Check if storage is RocksDB
	if (this->_storage->get_type() != storage::type_rocksdb) {
		log_warning("repl_sync_wal requested but storage is not RocksDB", 0);
		return this->_send_result(result_server_error, "not_supported");
	}

	storage_rocksdb* rocksdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rocksdb) {
		log_err("failed to cast storage to storage_rocksdb", 0);
		return this->_send_result(result_server_error, "internal_error");
	}

	// Master identity token check. A slave that is following a
	// different lineage (split-brain, restored from backup, synced
	// against a different cluster) must NOT be allowed to consume WAL
	// batches from us — it would silently corrupt its own data.
	// Instead, respond with master_id_mismatch; the slave will fall
	// back to a non-destructive full dump and adopt our token.
	const string server_master_id = rocksdb->get_master_id();
	if (!this->_client_master_id.empty() && this->_client_master_id != server_master_id) {
		log_notice("master_id mismatch (client=%s server=%s) -> slave must resync",
			this->_client_master_id.c_str(), server_master_id.c_str());
		rocksdb->incr_wal_sync_master_id_mismatch();
		string msg = "master_id_mismatch " + server_master_id;
		return this->_send_result(result_server_error, msg.c_str());
	}

	// Slave-ahead check: if the slave claims a sequence number beyond
	// anything we have produced, it came from a different (or newer)
	// master. Force a full dump rather than silently returning zero
	// updates, which would make the slave believe it is synchronized.
	uint64_t server_latest = rocksdb->get_latest_sequence_number();
	if (this->_lsn > server_latest) {
		log_warning("slave LSN (%llu) ahead of master latest (%llu) -> forcing resync",
			this->_lsn, server_latest);
		rocksdb->incr_wal_sync_lsn_ahead();
		char msg[BUFSIZ];
		snprintf(msg, sizeof(msg), "lsn_ahead %llu", (unsigned long long)server_latest);
		return this->_send_result(result_server_error, msg);
	}

	// Get updates since requested LSN
	vector<pair<uint64_t, rocksdb::WriteBatch>> updates;
	int result = rocksdb->get_updates_since(this->_lsn, updates);

	if (result == storage_rocksdb::ERR_LSN_PURGED) {
		log_notice("LSN %llu purged from WAL, slave needs full sync", this->_lsn);
		rocksdb->incr_wal_sync_lsn_purged();
		return this->_send_result(result_server_error, "lsn_purged");
	}

	if (result < 0) {
		log_err("get_updates_since failed for LSN %llu", this->_lsn);
		rocksdb->incr_wal_sync_other_error();
		return this->_send_result(result_server_error, "wal_read_error");
	}

	{
		uint64_t first_seq = updates.empty() ? 0 : updates.front().first;
		uint64_t last_seq  = updates.empty() ? 0 : updates.back().first;
		log_info("streaming %zu WAL updates from LSN %llu (range %llu..%llu, server_latest=%llu, master_id=%s)",
			updates.size(), (unsigned long long)this->_lsn,
			(unsigned long long)first_seq, (unsigned long long)last_seq,
			(unsigned long long)server_latest,
			server_master_id.c_str());
	}

	// Optional throttling for the WAL streaming path. A zero bwlimit
	// means "no rate cap"; a zero interval means "no per-batch
	// sleep". The bwlimiter is local so the config is scoped to this
	// single WAL sync and never leaks into other paths.
	bwlimitter throttler;
	if (this->_bwlimit_kbps > 0) {
		throttler.set_bwlimit(static_cast<uint64_t>(this->_bwlimit_kbps));
	}

	// Stream updates to client
	for (size_t i = 0; i < updates.size(); i++) {
		uint64_t seq = updates[i].first;
		rocksdb::WriteBatch& batch = updates[i].second;
		string batch_data = batch.Data();

		// Enforce the configured batch-size ceiling. A single huge
		// WriteBatch (multi-megabyte append, or a burst bulk write)
		// can outgrow the slave's receive buffer or the message-
		// framing assumptions in this protocol. Rather than try to
		// chunk — which would break WriteBatch atomicity — we abort
		// WAL sync and let the caller fall through to the non-
		// destructive full-dump path. Counter is incremented on the
		// server side so operators see it in their own stats.
		if (this->_max_batch_bytes > 0 && batch_data.size() > this->_max_batch_bytes) {
			log_warning("WAL batch at LSN %llu exceeds limit (size=%zu limit=%llu) -> batch_too_large",
				(unsigned long long)seq, batch_data.size(),
				(unsigned long long)this->_max_batch_bytes);
			rocksdb->incr_wal_sync_other_error();
			char msg[BUFSIZ];
			snprintf(msg, sizeof(msg), "batch_too_large %zu", batch_data.size());
			return this->_send_result(result_server_error, msg);
		}

		// Send LSN marker
		char lsn_line[BUFSIZ];
		snprintf(lsn_line, sizeof(lsn_line), "LSN %llu%s", (unsigned long long)seq, line_delimiter);
		this->_connection->write(lsn_line, strlen(lsn_line));

		// Stream entries from WriteBatch
		// We need to iterate through the batch and send each key-value pair
		// For now, we'll send the raw batch data
		// TODO: Implement proper batch iteration and send as memcached protocol
		char batch_line[BUFSIZ];
		snprintf(batch_line, sizeof(batch_line), "BATCH %zu%s", batch_data.size(), line_delimiter);
		this->_connection->write(batch_line, strlen(batch_line));
		this->_connection->write(batch_data.data(), batch_data.size());
		this->_connection->write(line_delimiter, strlen(line_delimiter));

		// Throttling: sleep according to the configured bandwidth
		// cap for the bytes we just sent, then apply any additional
		// per-batch interval. Skipped entirely for the common case
		// of both being zero.
		if (this->_bwlimit_kbps > 0) {
			long elapsed_usec = throttler.sleep_for_bwlimit(
				batch_data.size() + strlen(lsn_line) + strlen(batch_line) + strlen(line_delimiter));
			if (this->_interval_usec > 0 && this->_interval_usec > elapsed_usec) {
				usleep(this->_interval_usec - elapsed_usec);
			}
		} else if (this->_interval_usec > 0) {
			usleep(this->_interval_usec);
		}
	}

	return this->_send_result(result_end);
#else
	log_warning("repl_sync_wal requested but RocksDB not compiled in", 0);
	return this->_send_result(result_server_error, "not_compiled");
#endif
}

int op_repl_sync_wal::_run_client(uint64_t lsn, const string& master_id) {
	char request[BUFSIZ];
	const char* id = master_id.empty() ? "-" : master_id.c_str();
	snprintf(request, sizeof(request), "repl_sync_wal %llu %s",
		(unsigned long long)lsn, id);
	return this->_send_request(request);
}

int op_repl_sync_wal::_parse_text_client_parameters() {
#ifdef HAVE_LIBROCKSDB
	if (this->_storage->get_type() != storage::type_rocksdb) {
		log_err("slave storage is not RocksDB, cannot apply WAL", 0);
		this->_client_result = client_not_supported;
		return -1;
	}

	storage_rocksdb* rocksdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rocksdb) {
		log_err("failed to cast storage to storage_rocksdb", 0);
		this->_client_result = client_server_error;
		return -1;
	}

	// Read response lines
	for (;;) {
		char* p;
		if (this->_connection->readline(&p) < 0) {
			log_err("connection error while reading WAL stream", 0);
			this->_client_result = client_protocol_error;
			return -1;
		}

		// Check for end or error
		if (strcmp(p, "END\n") == 0) {
			delete[] p;
			break;
		}

		if (strncmp(p, "SERVER_ERROR", 12) == 0) {
			// Classify the reason so the caller can decide whether to
			// fall back to a full dump and, if so, whether to adopt a
			// new master identity. Counters are incremented on the
			// slave side as well so operators can see the failure from
			// either end of the connection via `stats`.
			const char* body = p + 12;
			while (*body == ' ') body++;
			if (strncmp(body, "master_id_mismatch", 18) == 0) {
				const char* id = body + 18;
				while (*id == ' ') id++;
				// strip trailing \r\n
				string server_id = id;
				while (!server_id.empty() &&
					(server_id[server_id.size() - 1] == '\n' ||
					 server_id[server_id.size() - 1] == '\r')) {
					server_id.erase(server_id.size() - 1);
				}
				this->_server_master_id = server_id;
				this->_client_result = client_master_id_mismatch;
				rocksdb->incr_wal_sync_master_id_mismatch();
				log_warning("master_id mismatch (server reports %s)", server_id.c_str());
			} else if (strncmp(body, "lsn_ahead", 9) == 0) {
				this->_client_result = client_lsn_ahead;
				rocksdb->incr_wal_sync_lsn_ahead();
				log_warning("slave LSN ahead of master (%s)", body);
			} else if (strncmp(body, "lsn_purged", 10) == 0) {
				this->_client_result = client_lsn_purged;
				rocksdb->incr_wal_sync_lsn_purged();
				log_notice("master reports lsn_purged -> full dump required", 0);
			} else if (strncmp(body, "not_supported", 13) == 0 ||
			           strncmp(body, "not_compiled", 12) == 0) {
				this->_client_result = client_not_supported;
				log_notice("WAL sync not supported by peer", 0);
			} else if (strncmp(body, "batch_too_large", 15) == 0) {
				// The peer had a single WriteBatch that exceeded
				// its rocksdb_wal_max_batch_bytes ceiling. This is
				// classified as a transport failure, not a lineage
				// or data-integrity problem, so the caller still
				// falls back to full dump (which sends key-by-key
				// and is not subject to this limit).
				this->_client_result = client_server_error;
				rocksdb->incr_wal_sync_other_error();
				log_warning("WAL sync aborted: %s", body);
			} else {
				this->_client_result = client_server_error;
				rocksdb->incr_wal_sync_other_error();
				log_warning("server error during WAL sync: %s", p);
			}
			delete[] p;
			return -1;
		}

		// Parse LSN line
		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "LSN") == 0) {
			n += util::next_digit(p+n, q, sizeof(q));
			uint64_t lsn = boost::lexical_cast<uint64_t>(q);
			log_debug("received LSN %llu", lsn);

			delete[] p;

			// Read BATCH line
			if (this->_connection->readline(&p) < 0) {
				log_err("connection error while reading BATCH line", 0);
				return -1;
			}

			n = util::next_word(p, q, sizeof(q));
			if (strcmp(q, "BATCH") != 0) {
				log_err("expected BATCH, got %s", q);
				delete[] p;
				return -1;
			}

			n += util::next_digit(p+n, q, sizeof(q));
			size_t batch_size = boost::lexical_cast<size_t>(q);
			delete[] p;

			// Read batch data
			char* batch_data = NULL;
			bool actual = false;
			if (this->_connection->read(&batch_data, batch_size, false, actual) < 0) {
				log_err("failed to read batch data", 0);
				if (batch_data) delete[] batch_data;
				return -1;
			}

			// Read trailing newline
			if (this->_connection->readline(&p) < 0) {
				delete[] batch_data;
				return -1;
			}
			delete[] p;

			// Apply batch
			rocksdb::WriteBatch batch(string(batch_data, batch_size));
			delete[] batch_data;

			int result = rocksdb->apply_batch_with_lsn(batch, lsn);
			if (result < 0) {
				log_err("failed to apply batch for LSN %llu", lsn);
				this->_client_result = client_apply_error;
				rocksdb->incr_wal_sync_apply_failure();
				return -1;
			}

			log_debug("applied batch for LSN %llu (batch_size=%zu)", lsn, batch_size);
		} else {
			log_warning("unexpected line in WAL stream: %s", p);
			delete[] p;
		}
	}

	log_notice("WAL sync completed successfully (last_applied_lsn=%llu, master_id=%s)",
		(unsigned long long)rocksdb->get_repl_last_lsn(),
		rocksdb->get_master_id().c_str());
	this->_client_result = client_success;
	rocksdb->incr_wal_sync_success();
	return 0;
#else
	log_err("RocksDB not compiled in, cannot apply WAL", 0);
	this->_client_result = client_not_supported;
	return -1;
#endif
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
