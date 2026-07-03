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
 *	implementation of gree::flare::op_repl_sync_wal (push protocol;
 *	see op_repl_sync_wal.h for the wire format)
 *
 *	$Id$
 */
#include "op_repl_sync_wal.h"
#include "cluster.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_repl_sync_wal
 */
op_repl_sync_wal::op_repl_sync_wal(shared_connection c, storage* st, cluster* cl):
		op(c, "repl_sync_wal"),
		_storage(st),
		_cluster(cl),
		_server_mode(mode_none),
		_seed_lsn(0),
		_client_source_id(""),
		_server_source_id(""),
		_client_result(client_server_error),
		_connection_dirty(false),
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
 *	push our WAL delta to the destination. See op_repl_sync_wal.h for
 *	the exchange; on return get_client_result() classifies the outcome
 *	and connection_dirty() tells the caller whether the connection is
 *	still line-synchronized.
 */
int op_repl_sync_wal::run_client_push(const string& source_id) {
#ifdef HAVE_LIBROCKSDB
	this->_client_result = client_server_error;
	this->_connection_dirty = false;

	if (!this->_storage || this->_storage->get_type() != storage::type_rocksdb) {
		log_err("local storage is not RocksDB, cannot stream WAL", 0);
		this->_client_result = client_not_supported;
		return -1;
	}
	storage_rocksdb* rocksdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rocksdb) {
		log_err("failed to cast storage to storage_rocksdb", 0);
		this->_client_result = client_not_supported;
		return -1;
	}

	char request[BUFSIZ];
	const char* id = source_id.empty() ? "-" : source_id.c_str();
	snprintf(request, sizeof(request), "repl_sync_wal begin %s", id);
	if (this->_send_request(request) < 0) {
		this->_client_result = client_protocol_error;
		this->_connection_dirty = true;
		return -1;
	}

	// The destination answers with its recorded position in our WAL
	// lineage ("LSN <n>"), or refuses with a single line.
	char* p;
	if (this->_connection->readline(&p) < 0) {
		log_err("connection error while reading begin response", 0);
		this->_client_result = client_protocol_error;
		this->_connection_dirty = true;
		return -1;
	}

	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (strcmp(q, "SERVER_ERROR") == 0) {
		const char* body = p + n;
		while (*body == ' ') body++;
		if (strncmp(body, "master_id_mismatch", 18) == 0) {
			const char* sid = body + 18;
			while (*sid == ' ') sid++;
			string server_id = sid;
			while (!server_id.empty() &&
				(server_id[server_id.size() - 1] == '\n' ||
				 server_id[server_id.size() - 1] == '\r')) {
				server_id.erase(server_id.size() - 1);
			}
			this->_server_source_id = server_id;
			this->_client_result = client_master_id_mismatch;
			rocksdb->incr_wal_sync_master_id_mismatch();
			log_notice("destination follows a different replication source (dest recorded=%s) -> full dump required", server_id.c_str());
		} else if (strncmp(body, "not_supported", 13) == 0 ||
		           strncmp(body, "not_compiled", 12) == 0 ||
		           strncmp(body, "topology_unsupported", 20) == 0) {
			this->_client_result = client_not_supported;
			log_notice("WAL sync not applicable to peer (%s) -> full dump", body);
		} else {
			this->_client_result = client_server_error;
			rocksdb->incr_wal_sync_other_error();
			log_warning("server error on repl_sync_wal begin: %s", p);
		}
		delete[] p;
		return -1;
	}
	if (strcmp(q, "ERROR") == 0) {
		// old flared (or a build without RocksDB) that doesn't know the op
		this->_client_result = client_not_supported;
		log_notice("peer does not understand repl_sync_wal", 0);
		delete[] p;
		return -1;
	}
	if (strcmp(q, "LSN") != 0) {
		log_warning("unexpected begin response [%s]", p);
		this->_client_result = client_protocol_error;
		this->_connection_dirty = true;
		delete[] p;
		return -1;
	}

	uint64_t dest_lsn = 0;
	util::next_digit(p+n, q, sizeof(q));
	delete[] p;
	try {
		dest_lsn = boost::lexical_cast<uint64_t>(q);
	} catch (boost::bad_lexical_cast e) {
		// the destination is now waiting for batches; abort the stream
		// so both sides stay line-synchronized
		log_warning("invalid LSN in begin response [%s]", q);
		this->_client_result = client_protocol_error;
		return this->_abort_stream("protocol_error");
	}

	if (this->_stream_batches(rocksdb, dest_lsn) < 0) {
		return -1;
	}

	if (this->_connection->writeline("END") < 0) {
		this->_client_result = client_protocol_error;
		this->_connection_dirty = true;
		return -1;
	}
	return this->_read_final_result();
#else
	log_err("RocksDB not compiled in, cannot stream WAL", 0);
	this->_client_result = client_not_supported;
	return -1;
#endif
}

/**
 *	tell the destination which source (our sequence domain) it now
 *	follows and the WAL position our full dump covered, enabling
 *	incremental syncs from now on.
 */
int op_repl_sync_wal::run_client_seed(const string& source_id, uint64_t lsn) {
	this->_client_result = client_server_error;
	this->_connection_dirty = false;

	if (source_id.empty()) {
		log_err("refusing to seed an empty source id", 0);
		return -1;
	}

	char request[BUFSIZ];
	snprintf(request, sizeof(request), "repl_sync_wal seed %s %llu",
		source_id.c_str(), (unsigned long long)lsn);
	if (this->_send_request(request) < 0) {
		this->_client_result = client_protocol_error;
		this->_connection_dirty = true;
		return -1;
	}

	char* p;
	if (this->_connection->readline(&p) < 0) {
		this->_client_result = client_protocol_error;
		this->_connection_dirty = true;
		return -1;
	}

	char q[BUFSIZ];
	util::next_word(p, q, sizeof(q));
	if (strcmp(q, "OK") == 0) {
		log_notice("seeded destination (source_id=%s, lsn=%llu)",
			source_id.c_str(), (unsigned long long)lsn);
		this->_client_result = client_success;
		delete[] p;
		return 0;
	}
	if (strcmp(q, "SERVER_ERROR") == 0 || strcmp(q, "ERROR") == 0) {
		log_warning("destination refused seed: %s", p);
		this->_client_result = client_server_error;
		delete[] p;
		return -1;
	}
	log_warning("unexpected seed response [%s]", p);
	this->_client_result = client_protocol_error;
	this->_connection_dirty = true;
	delete[] p;
	return -1;
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 *
 *	syntax:
 *	REPL_SYNC_WAL begin <source_id>
 *	REPL_SYNC_WAL seed <source_id> <lsn>
 *
 *	<source_id> is the source node's own master_id (its WAL sequence
 *	domain); "-" means "no source id".
 */
int op_repl_sync_wal::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (strcmp(q, "begin") == 0) {
		this->_server_mode = mode_begin;
	} else if (strcmp(q, "seed") == 0) {
		this->_server_mode = mode_seed;
	} else {
		log_warning("unknown repl_sync_wal subcommand [%s]", q);
		delete[] p;
		return -1;
	}

	n += util::next_word(p+n, q, sizeof(q));
	if (q[0] == '\0') {
		log_warning("no source id specified", 0);
		delete[] p;
		return -1;
	}
	if (strcmp(q, "-") != 0) {
		this->_client_source_id = q;
	}

	if (this->_server_mode == mode_seed) {
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_warning("no seed LSN specified", 0);
			delete[] p;
			return -1;
		}
		try {
			this->_seed_lsn = boost::lexical_cast<uint64_t>(q);
		} catch (boost::bad_lexical_cast e) {
			log_warning("invalid seed LSN [%s]", q);
			delete[] p;
			return -1;
		}
	}

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
	if (!this->_storage || this->_storage->get_type() != storage::type_rocksdb) {
		log_warning("repl_sync_wal requested but storage is not RocksDB", 0);
		return this->_send_result(result_server_error, "not_supported");
	}

	storage_rocksdb* rocksdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rocksdb) {
		log_err("failed to cast storage to storage_rocksdb", 0);
		return this->_send_result(result_server_error, "internal_error");
	}

	switch (this->_server_mode) {
	case mode_begin:
		return this->_run_server_begin(rocksdb);
	case mode_seed:
		return this->_run_server_seed(rocksdb);
	default:
		return this->_send_result(result_server_error, "not_supported");
	}
#else
	log_warning("repl_sync_wal requested but RocksDB not compiled in", 0);
	return this->_send_result(result_server_error, "not_compiled");
#endif
}

#ifdef HAVE_LIBROCKSDB
/**
 *	destination side of `repl_sync_wal begin`: report our recorded
 *	position in the source's lineage, then receive and apply the
 *	streamed batches.
 */
int op_repl_sync_wal::_run_server_begin(storage_rocksdb* rocksdb) {
	// Topology check. WAL batches are applied to THIS node's local
	// storage directly, bypassing the destination cluster's key
	// routing and slave fan-out. In any topology wider than a single
	// partition with no slave, that would misplace keys or leave our
	// own slaves stale, so we refuse and let the source fall back to a
	// full dump (which goes through op_set and is routed correctly).
	if (!this->_cluster || !this->_cluster->is_wal_sync_destination_safe()) {
		log_notice("repl_sync_wal begin refused: destination topology not eligible for WAL sync -> full dump", 0);
		rocksdb->incr_wal_sync_other_error();
		return this->_send_result(result_server_error, "topology_unsupported");
	}

	// Sequence-domain check. `repl_last_lsn` is a position in ONE
	// physical DB's WAL — the source that seeded us. Applying batches
	// whose sequence numbers come from a different domain would make
	// our recorded position meaningless and silently skip a gap. The
	// source names its own sequence domain (its master_id) as the
	// source id; we require it to equal the source we were last seeded
	// by. On mismatch (or if we were never seeded) the source falls
	// back to a non-destructive full dump and re-seeds us.
	string recorded_source = rocksdb->get_repl_source_id();
	if (this->_client_source_id.empty() || recorded_source.empty()
			|| this->_client_source_id != recorded_source) {
		log_notice("replication source mismatch (source=%s recorded=%s) -> full dump required",
			this->_client_source_id.empty() ? "-" : this->_client_source_id.c_str(),
			recorded_source.empty() ? "-" : recorded_source.c_str());
		rocksdb->incr_wal_sync_master_id_mismatch();
		string msg = "master_id_mismatch " + recorded_source;
		return this->_send_result(result_server_error, msg.c_str());
	}

	uint64_t last_lsn = rocksdb->get_repl_last_lsn();
	char lsn_line[BUFSIZ];
	snprintf(lsn_line, sizeof(lsn_line), "LSN %llu", (unsigned long long)last_lsn);
	if (this->_connection->writeline(lsn_line) < 0) {
		log_err("failed to send LSN response", 0);
		return -1;
	}

	uint64_t last_applied = last_lsn;
	bool aborted = false;
	string fail_reason;
	if (this->_receive_batches(rocksdb, last_applied, aborted, fail_reason) < 0) {
		// transport failure or unrecoverable framing error; the
		// connection is dead, no final result can be delivered
		return -1;
	}

	if (!fail_reason.empty()) {
		return this->_send_result(result_server_error, fail_reason.c_str());
	}
	if (aborted) {
		// the source explained why; just acknowledge so it can reuse
		// the connection
		return this->_send_result(result_ok, "aborted");
	}
	char msg[64];
	snprintf(msg, sizeof(msg), "%llu", (unsigned long long)last_applied);
	log_notice("WAL sync applied up to LSN %llu (source=%s)",
		(unsigned long long)last_applied, recorded_source.c_str());
	rocksdb->incr_wal_sync_success();
	return this->_send_result(result_ok, msg);
}

/**
 *	destination side of `repl_sync_wal seed`: record which source
 *	(sequence domain) our data now follows and the position in that
 *	source's WAL that the full dump covered. Recorded atomically so a
 *	crash can never pair a new source id with a stale position. This
 *	does NOT touch our own master_id.
 */
int op_repl_sync_wal::_run_server_seed(storage_rocksdb* rocksdb) {
	// Recording a source id promises the next `begin` will apply WAL
	// batches locally; only accept it while the topology remains WAL-
	// eligible, so a node that grew slaves/partitions after its dump
	// does not later apply un-routed batches.
	if (!this->_cluster || !this->_cluster->is_wal_sync_destination_safe()) {
		log_notice("repl_sync_wal seed refused: destination topology not eligible for WAL sync", 0);
		return this->_send_result(result_server_error, "topology_unsupported");
	}
	if (this->_client_source_id.empty()) {
		log_warning("seed with empty source id -> refusing", 0);
		return this->_send_result(result_server_error, "invalid_seed");
	}
	if (rocksdb->set_repl_source(this->_client_source_id, this->_seed_lsn) < 0) {
		return this->_send_result(result_server_error, "seed_failed");
	}
	log_notice("recorded replication source (source_id=%s, lsn=%llu)",
		this->_client_source_id.c_str(), (unsigned long long)this->_seed_lsn);
	return this->_send_result(result_ok);
}

/**
 *	receive "LSN/BATCH/<data>" records until END or ABORT, applying each
 *	batch in order. After the first failure the remaining records are
 *	drained (to keep the connection synchronized) but not applied, so
 *	the destination never applies batches with a gap. Returns -1 only
 *	on transport/framing errors that leave the connection unusable.
 */
int op_repl_sync_wal::_receive_batches(storage_rocksdb* rocksdb, uint64_t& last_applied,
		bool& aborted, string& fail_reason) {
	for (;;) {
		// On a graceful shutdown, stop applying but keep draining the
		// stream so the connection stays framed (the source is told via
		// the final SERVER_ERROR and falls back to a full dump next
		// time). Never leave the socket mid-record — that is why we do
		// not simply break out here.
		if (fail_reason.empty() && this->_shutdown_requested()) {
			log_notice("shutdown requested during WAL receive -> draining remaining stream", 0);
			fail_reason = "shutdown";
		}

		char* p;
		if (this->_connection->readline(&p) < 0) {
			log_err("connection error while reading WAL stream", 0);
			return -1;
		}

		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "END") == 0) {
			delete[] p;
			return 0;
		}
		if (strcmp(q, "ABORT") == 0) {
			log_notice("source aborted WAL stream: %s", p+n);
			aborted = true;
			delete[] p;
			return 0;
		}
		if (strcmp(q, "LSN") != 0) {
			log_err("expected LSN/END/ABORT, got [%s]", p);
			delete[] p;
			return -1;
		}

		uint64_t seq;
		util::next_digit(p+n, q, sizeof(q));
		delete[] p;
		try {
			seq = boost::lexical_cast<uint64_t>(q);
		} catch (boost::bad_lexical_cast e) {
			log_err("invalid LSN in WAL stream [%s]", q);
			return -1;
		}

		if (this->_connection->readline(&p) < 0) {
			log_err("connection error while reading BATCH line", 0);
			return -1;
		}
		n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "BATCH") != 0) {
			log_err("expected BATCH, got [%s]", p);
			delete[] p;
			return -1;
		}
		uint64_t batch_size;
		util::next_digit(p+n, q, sizeof(q));
		delete[] p;
		try {
			batch_size = boost::lexical_cast<uint64_t>(q);
		} catch (boost::bad_lexical_cast e) {
			log_err("invalid BATCH size in WAL stream [%s]", q);
			return -1;
		}

		// Size guards: reject batches over the operator-configured
		// ceiling or the absolute hard limit, but keep reading (and
		// discarding) the declared bytes so the stream stays framed.
		uint64_t ceiling = rocksdb->get_wal_max_batch_bytes();
		bool too_large = batch_size > max_batch_bytes_hard_limit
			|| (ceiling > 0 && batch_size > ceiling);
		if (too_large) {
			log_warning("WAL batch at LSN %llu exceeds limit (size=%llu) -> discarding stream",
				(unsigned long long)seq, (unsigned long long)batch_size);
			if (fail_reason.empty()) {
				fail_reason = "batch_too_large";
				rocksdb->incr_wal_sync_other_error();
			}
			uint64_t remaining = batch_size + 2;	// + trailing CRLF
			while (remaining > 0) {
				int chunk = remaining > (1 << 20) ? (1 << 20) : (int)remaining;
				char* buf = NULL;
				if (this->_connection->readsize(chunk, &buf) < 0) {
					return -1;
				}
				delete[] buf;
				remaining -= chunk;
			}
			continue;
		}

		char* batch_data = NULL;
		if (this->_connection->readsize((int)(batch_size + 2), &batch_data) < 0) {
			log_err("failed to read batch data (size=%llu)", (unsigned long long)batch_size);
			return -1;
		}

		if (fail_reason.empty()) {
			rocksdb::WriteBatch batch(string(batch_data, batch_size));
			if (rocksdb->apply_batch_with_lsn(batch, seq) < 0) {
				log_err("failed to apply batch for LSN %llu", (unsigned long long)seq);
				fail_reason = "apply_error";
				rocksdb->incr_wal_sync_apply_failure();
			} else {
				last_applied = seq;
				log_debug("applied batch for LSN %llu (batch_size=%llu)",
					(unsigned long long)seq, (unsigned long long)batch_size);
			}
		}
		delete[] batch_data;
	}
}

/**
 *	source side: fetch the WAL delta after dest_lsn in bounded chunks
 *	and stream each batch. The LSN marker sent with a batch is the
 *	sequence of its LAST operation, so the position the destination
 *	records lets the next sync resume without a gap.
 */
int op_repl_sync_wal::_stream_batches(storage_rocksdb* rocksdb, uint64_t dest_lsn) {
	uint64_t local_latest = rocksdb->get_latest_sequence_number();
	if (dest_lsn > local_latest) {
		// The destination has seen more of "our" WAL than we have — we
		// lost data (restored from backup?) or the lineage token was
		// reused. Force a full resync.
		log_warning("dest LSN (%llu) ahead of local latest (%llu) -> forcing full resync",
			(unsigned long long)dest_lsn, (unsigned long long)local_latest);
		rocksdb->incr_wal_sync_lsn_ahead();
		this->_client_result = client_lsn_ahead;
		return this->_abort_stream("lsn_ahead");
	}

	bwlimitter throttler;
	if (this->_bwlimit_kbps > 0) {
		throttler.set_bwlimit(static_cast<uint64_t>(this->_bwlimit_kbps));
	}

	uint64_t from_lsn = dest_lsn;
	uint64_t streamed = 0;
	bool has_more = true;
	int fetch_iterations = 0;
	while (has_more) {
		// Abandon a non-converging catch-up: if the local write rate
		// stays above the throttled send rate, get_updates_since keeps
		// reporting has_more forever and the resync never completes. Cap
		// the number of chunks and fall back to a full dump instead.
		if (++fetch_iterations > max_fetch_iterations) {
			log_notice("WAL catch-up not converging after %d chunks (still %llu behind) -> full dump",
				max_fetch_iterations,
				(unsigned long long)(rocksdb->get_latest_sequence_number() - from_lsn));
			rocksdb->incr_wal_sync_other_error();
			this->_client_result = client_server_error;
			return this->_abort_stream("not_converging");
		}

		// Honor a graceful shutdown between chunks so the thread can
		// exit promptly instead of streaming a multi-GB backlog.
		if (this->_shutdown_requested()) {
			log_notice("shutdown requested during WAL stream -> aborting", 0);
			this->_client_result = client_server_error;
			return this->_abort_stream("shutdown");
		}

		has_more = false;
		vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
		int result = rocksdb->get_updates_since(from_lsn, updates, fetch_chunk_bytes, &has_more);
		if (result == storage_rocksdb::ERR_LSN_PURGED) {
			log_notice("WAL no longer covers LSN %llu -> destination needs full dump",
				(unsigned long long)from_lsn);
			rocksdb->incr_wal_sync_lsn_purged();
			this->_client_result = client_lsn_purged;
			return this->_abort_stream("lsn_purged");
		}
		if (result < 0) {
			log_err("get_updates_since failed for LSN %llu", (unsigned long long)from_lsn);
			rocksdb->incr_wal_sync_other_error();
			this->_client_result = client_server_error;
			return this->_abort_stream("wal_read_error");
		}

		uint64_t chunk_start_lsn = from_lsn;
		for (size_t i = 0; i < updates.size(); i++) {
			uint64_t seq = updates[i].first;
			rocksdb::WriteBatch& batch = updates[i].second;
			int count = batch.Count();
			uint64_t end_seq = seq + (count > 0 ? count - 1 : 0);
			if (end_seq <= from_lsn) {
				// entirely covered by the destination's position (the
				// first batch of a fetch may overlap it)
				continue;
			}
			string batch_data = batch.Data();

			// Enforce the configured batch-size ceiling. A single huge
			// WriteBatch can outgrow the destination's limits; rather
			// than chunk it — which would break WriteBatch atomicity —
			// abort and let the caller fall back to the full dump.
			if (this->_max_batch_bytes > 0 && batch_data.size() > this->_max_batch_bytes) {
				log_warning("WAL batch at LSN %llu exceeds limit (size=%zu limit=%llu) -> batch_too_large",
					(unsigned long long)seq, batch_data.size(),
					(unsigned long long)this->_max_batch_bytes);
				rocksdb->incr_wal_sync_other_error();
				this->_client_result = client_server_error;
				return this->_abort_stream("batch_too_large");
			}

			char lsn_line[BUFSIZ];
			snprintf(lsn_line, sizeof(lsn_line), "LSN %llu%s", (unsigned long long)end_seq, line_delimiter);
			char batch_line[BUFSIZ];
			snprintf(batch_line, sizeof(batch_line), "BATCH %zu%s", batch_data.size(), line_delimiter);
			if (this->_connection->write(lsn_line, strlen(lsn_line)) < 0
					|| this->_connection->write(batch_line, strlen(batch_line)) < 0
					|| this->_connection->write(batch_data.data(), batch_data.size()) < 0
					|| this->_connection->write(line_delimiter, strlen(line_delimiter)) < 0) {
				log_err("connection error while streaming WAL batch", 0);
				this->_client_result = client_protocol_error;
				this->_connection_dirty = true;
				return -1;
			}

			// Throttling: sleep according to the configured bandwidth
			// cap for the bytes we just sent, then apply any additional
			// per-batch interval.
			if (this->_bwlimit_kbps > 0) {
				long elapsed_usec = throttler.sleep_for_bwlimit(
					batch_data.size() + strlen(lsn_line) + strlen(batch_line) + strlen(line_delimiter));
				if (this->_interval_usec > 0 && this->_interval_usec > elapsed_usec) {
					usleep(this->_interval_usec - elapsed_usec);
				}
			} else if (this->_interval_usec > 0) {
				usleep(this->_interval_usec);
			}

			from_lsn = end_seq;
			streamed++;
		}

		if (has_more && from_lsn == chunk_start_lsn) {
			// no forward progress although more data is pending —
			// should not happen, but never spin here
			log_err("WAL streaming stalled at LSN %llu -> aborting", (unsigned long long)from_lsn);
			rocksdb->incr_wal_sync_other_error();
			this->_client_result = client_server_error;
			return this->_abort_stream("wal_read_error");
		}
	}

	log_info("streamed %llu WAL batches (dest_lsn=%llu -> %llu)",
		(unsigned long long)streamed, (unsigned long long)dest_lsn,
		(unsigned long long)from_lsn);
	return 0;
}

/**
 *	terminate the stream early but keep both sides line-synchronized:
 *	tell the destination why, and consume its acknowledgment.
 */
int op_repl_sync_wal::_abort_stream(const char* reason) {
	char line[BUFSIZ];
	snprintf(line, sizeof(line), "ABORT %s", reason);
	if (this->_connection->writeline(line) < 0) {
		this->_connection_dirty = true;
		return -1;
	}
	char* p;
	if (this->_connection->readline(&p) < 0) {
		this->_connection_dirty = true;
		return -1;
	}
	delete[] p;
	return -1;
}

/**
 *	read the destination's final verdict after END.
 */
int op_repl_sync_wal::_read_final_result() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		log_err("connection error while reading final result", 0);
		this->_client_result = client_protocol_error;
		this->_connection_dirty = true;
		return -1;
	}

	storage_rocksdb* rocksdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (strcmp(q, "OK") == 0) {
		log_notice("WAL sync completed successfully (%s)", p+n);
		this->_client_result = client_success;
		if (rocksdb) {
			rocksdb->incr_wal_sync_success();
		}
		delete[] p;
		return 0;
	}
	if (strcmp(q, "SERVER_ERROR") == 0) {
		const char* body = p + n;
		while (*body == ' ') body++;
		if (strncmp(body, "apply_error", 11) == 0) {
			this->_client_result = client_apply_error;
			if (rocksdb) {
				rocksdb->incr_wal_sync_apply_failure();
			}
		} else {
			this->_client_result = client_server_error;
			if (rocksdb) {
				rocksdb->incr_wal_sync_other_error();
			}
		}
		log_warning("destination reported WAL sync failure: %s", p);
		delete[] p;
		return -1;
	}
	log_warning("unexpected final result [%s]", p);
	this->_client_result = client_protocol_error;
	this->_connection_dirty = true;
	delete[] p;
	return -1;
}
#endif	// HAVE_LIBROCKSDB
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
