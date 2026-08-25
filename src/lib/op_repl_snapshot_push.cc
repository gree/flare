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
 *	op_repl_snapshot_push.cc
 *
 *	implementation of gree::flare::op_repl_snapshot_push (see the header for
 *	the protocol and the WAL-retention/pinning rationale)
 */
#include "op_repl_snapshot_push.h"
#include "bwlimitter.h"
#include "connection_tcp.h"
#include "util.h"
#include <boost/lexical_cast.hpp>
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

#include <algorithm>
#include <dirent.h>
#include <sys/stat.h>
#include <stdio.h>

namespace gree {
namespace flare {

static const size_t kPushChunkBytes = 1024 * 1024;

// {{{ ctor/dtor
op_repl_snapshot_push::op_repl_snapshot_push(shared_connection c, cluster* cl, storage* st):
		op(c, "repl_snapshot_push"),
		_cluster(cl),
		_storage(st),
		_partition(0),
		_partition_size(0),
		_bwlimit(0),
		_relay(false),
		_client_result(client_result_none),
		_redirect_port(0) {
}

op_repl_snapshot_push::~op_repl_snapshot_push() {
}
// }}}

// {{{ public methods
int op_repl_snapshot_push::run_client(int partition, int partition_size) {
	return this->_run_client(partition, partition_size);
}
// }}}

// {{{ protected methods
int op_repl_snapshot_push::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (q[0]) {
		try {
			this->_partition = boost::lexical_cast<int>(q);
		} catch (...) {
			delete[] p;
			return -1;
		}
	}
	n += util::next_word(p + n, q, sizeof(q));
	if (q[0]) {
		try {
			this->_partition_size = boost::lexical_cast<int>(q);
		} catch (...) {
			delete[] p;
			return -1;
		}
	}
	n += util::next_word(p + n, q, sizeof(q));
	if (q[0]) {
		try {
			this->_bwlimit = boost::lexical_cast<uint64_t>(q);
		} catch (...) {
			// optional; ignore
		}
	}
	// optional trailing tokens (any order, forward compatible)
	for (;;) {
		n += util::next_word(p + n, q, sizeof(q));
		if (q[0] == '\0') {
			break;
		}
		if (strcmp(q, "relay=1") == 0) {
			this->_relay = true;
		}
	}
	delete[] p;
	return 0;
}

/**
 *	DESTINATION side: route to this partition's master (REDIRECT), guard
 *	freshness, then receive files + WAL tail and swap them in.
 */
int op_repl_snapshot_push::_run_server() {
#ifdef HAVE_LIBROCKSDB
	if (this->_storage == NULL || this->_storage->get_type() != storage::type_rocksdb) {
		return this->_send_result(result_server_error, "not_rocksdb");
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb == NULL) {
		return this->_send_result(result_server_error, "not_rocksdb");
	}
	if (this->_cluster == NULL) {
		return this->_send_result(result_server_error, "no_cluster");
	}

	// Route/authorize by role. A cross-cluster push must land on the local
	// master of that partition (a Service/LB can pin the connection to any
	// node -> redirect); an intra-destination RELAY hop (from our own master,
	// fanning the seed out) is accepted only by an Active slave of the
	// partition.
	{
		string self_key = this->_cluster->to_node_key(this->_cluster->get_server_name(), this->_cluster->get_server_port());
		vector<cluster::node> nodes = this->_cluster->get_node();
		string master_key;
		bool self_is_partition_slave = false;
		for (vector<cluster::node>::iterator it = nodes.begin(); it != nodes.end(); it++) {
			if (it->node_partition != this->_partition || it->node_state != cluster::state_active) {
				continue;
			}
			string key = this->_cluster->to_node_key(it->node_server_name, it->node_server_port);
			if (it->node_role == cluster::role_master && master_key.empty()) {
				master_key = key;
			}
			if (it->node_role == cluster::role_slave && key == self_key) {
				self_is_partition_slave = true;
			}
		}
		if (this->_relay) {
			if (!self_is_partition_slave) {
				log_warning("declining snapshot push relay hop: this node is not an Active slave of partition %d", this->_partition);
				return this->_send_result(result_server_error, "bad_relay_target");
			}
		} else {
			if (master_key.empty()) {
				return this->_send_result(result_server_error, "no_active_master_for_partition");
			}
			if (master_key != self_key) {
				string host;
				int port = 0;
				this->_cluster->from_node_key(master_key, host, port);
				char line[BUFSIZ];
				snprintf(line, sizeof(line), "REDIRECT %s %d\r\n", host.c_str(), port);
				log_notice("redirecting snapshot push for partition %d to its master [%s]", this->_partition, master_key.c_str());
				return this->_connection->write(line, strlen(line)) < 0 ? -1 : 0;
			}
		}
	}

	// Same partition layout on both sides or the per-partition key spaces do
	// not line up and a physical copy is meaningless. Evaluated AFTER the
	// role routing above ON PURPOSE: get_node_partition_map_size() counts
	// partitions with an Active master in THIS node's own map, so a
	// not-yet-converged node (e.g. a proxy wedged at partition=-1 after a
	// roll) reports 0 and used to hard-decline "partition_count_mismatch"
	// before the redirect could bounce the push to the real master
	// (observed live: 1p<->1p seed declined with source=1, local=0). After
	// the reorder only the partition's master answers this check.
	int local_partition_size = this->_cluster->get_node_partition_map_size();
	if (local_partition_size != this->_partition_size) {
		log_notice("declining snapshot push: partition count mismatch (source=%d, local=%d)",
			this->_partition_size, local_partition_size);
		return this->_send_result(result_server_error, "partition_count_mismatch");
	}

	// Freshness guard: replacing real data is the operator's call, never an
	// implicit side effect. The tolerance absorbs the live-duplicate trickle
	// that lands between `enable` and this push — every one of those keys
	// originated on the source and is inside the checkpoint ∪ WAL tail, so
	// the swap loses nothing.
	uint64_t local_items = this->_storage->count();
	if (local_items > op_repl_snapshot_push::fresh_destination_threshold) {
		log_notice("declining snapshot push: destination not fresh (curr_items=%llu > %llu)",
			(unsigned long long)local_items,
			(unsigned long long)op_repl_snapshot_push::fresh_destination_threshold);
		return this->_send_result(result_server_error, "not_fresh");
	}

	if (this->_connection->write("OK\r\n", 4) < 0) {
		return -1;
	}

	// ---- files: same receive/verify/swap flow as op_repl_snapshot's client ----
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (strcmp(q, "SNAPSHOT") != 0) {
		log_err("snapshot push desync (expected SNAPSHOT, got [%s])", p);
		delete[] p;
		return -1;
	}
	n += util::next_word(p + n, q, sizeof(q));
	uint64_t cp_seq = 0;
	try {
		cp_seq = boost::lexical_cast<uint64_t>(q);
	} catch (...) {
		delete[] p;
		return -1;
	}
	n += util::next_word(p + n, q, sizeof(q));		// master_id (in the files)
	n += util::next_word(p + n, q, sizeof(q));
	uint64_t nfiles = 0;
	try {
		nfiles = boost::lexical_cast<uint64_t>(q);
	} catch (...) {
		delete[] p;
		return -1;
	}
	delete[] p;

	string staging;
	if (rdb->prepare_snapshot_staging(staging) < 0) {
		return -1;
	}
	log_notice("snapshot push: receiving %llu files (seq=%llu, partition=%d)",
		(unsigned long long)nfiles, (unsigned long long)cp_seq, this->_partition);

	int r = 0;
	for (uint64_t i = 0; i < nfiles && r == 0; i++) {
		if (this->_connection->readline(&p) < 0) {
			r = -1;
			break;
		}
		n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "FILE") != 0) {
			log_err("snapshot push desync (expected FILE, got [%s])", p);
			delete[] p;
			r = -1;
			break;
		}
		n += util::next_word(p + n, q, sizeof(q));
		string name = q;
		n += util::next_word(p + n, q, sizeof(q));
		uint64_t size = 0;
		try {
			size = boost::lexical_cast<uint64_t>(q);
		} catch (...) {
			delete[] p;
			r = -1;
			break;
		}
		bool has_crc = false;
		uint32_t want_crc = 0;
		util::next_word(p + n, q, sizeof(q));
		if (q[0] != '\0') {
			try {
				want_crc = boost::lexical_cast<uint32_t>(q);
				has_crc = true;
			} catch (...) {
			}
		}
		delete[] p;

		if (name.empty() || name[0] == '.' || name.find('/') != string::npos) {
			log_err("refusing suspicious snapshot file name [%s]", name.c_str());
			r = -1;
			break;
		}

		string child = staging + "/" + name;
		FILE* fp = fopen(child.c_str(), "wb");
		if (fp == NULL) {
			log_err("failed to create staging file [%s]", child.c_str());
			r = -1;
			break;
		}
		uint64_t got_total = 0;
		uint32_t got_crc = 0;
		while (got_total < size) {
			int want = static_cast<int>(min<uint64_t>(kPushChunkBytes, size - got_total));
			char* data = NULL;
			if (this->_connection->readsize(want, &data) < 0 || data == NULL) {
				r = -1;
				break;
			}
			got_crc = util::crc32(got_crc, reinterpret_cast<const uint8_t*>(data), static_cast<size_t>(want));
			size_t written = fwrite(data, 1, want, fp);
			delete[] data;
			if (written != static_cast<size_t>(want)) {
				r = -1;
				break;
			}
			got_total += want;
		}
		fclose(fp);
		if (r == 0 && has_crc && got_crc != want_crc) {
			log_err("snapshot push file checksum mismatch [%s] (want=%u, got=%u)", name.c_str(), want_crc, got_crc);
			r = -1;
		}
	}
	if (r == 0) {
		if (this->_connection->readline(&p) < 0) {
			r = -1;
		} else {
			util::next_word(p, q, sizeof(q));
			if (strcmp(q, "END") != 0) {
				r = -1;
			}
			delete[] p;
		}
	}
	if (r < 0) {
		log_warning("snapshot push failed mid-stream -> declining (source falls back to dump)", 0);
		return -1;
	}

	// Intra-destination fan-out BEFORE our own swap: the seed arrives via
	// files, not via the write path, so our Active slaves would otherwise
	// silently stay empty (relay only ships normal writes). Best-effort per
	// slave — a failed hop is logged loudly and that slave stays diverged
	// until its next reconstruction; it never blocks the partition seed.
	vector<shared_connection> slave_sessions;
	if (!this->_relay) {
		this->_relay_staging_to_slaves(staging, cp_seq, slave_sessions);
	}

	// verification (CRC above + read-only structural probe inside) and swap
	if (rdb->swap_in_snapshot(staging, cp_seq) < 0) {
		return -1;
	}
	if (this->_connection->write("SWAPPED\r\n", 9) < 0) {
		return -1;
	}
	log_notice("snapshot push: swapped in (seq=%llu); receiving WAL tail", (unsigned long long)cp_seq);

	// ---- WAL tail: replay source-side writes committed since the checkpoint,
	// forwarding each batch to the slave sessions established above ----
	uint64_t applied = 0;
	for (;;) {
		if (this->_connection->readline(&p) < 0) {
			return -1;
		}
		n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "WEND") == 0) {
			delete[] p;
			break;
		}
		if (strcmp(q, "WBATCH") != 0) {
			log_err("snapshot push desync (expected WBATCH/WEND, got [%s])", p);
			delete[] p;
			return -1;
		}
		n += util::next_word(p + n, q, sizeof(q));
		uint64_t lsn = 0;
		try {
			lsn = boost::lexical_cast<uint64_t>(q);
		} catch (...) {
			delete[] p;
			return -1;
		}
		n += util::next_word(p + n, q, sizeof(q));
		uint64_t size = 0;
		try {
			size = boost::lexical_cast<uint64_t>(q);
		} catch (...) {
			delete[] p;
			return -1;
		}
		// Optional CRC-32 (3rd token; absent from older senders).
		bool has_crc = false;
		uint32_t want_crc = 0;
		util::next_word(p + n, q, sizeof(q));
		if (q[0] != '\0') {
			try {
				want_crc = boost::lexical_cast<uint32_t>(q);
				has_crc = true;
			} catch (...) {
				// unknown extra token: ignore (forward compatibility)
			}
		}
		delete[] p;

		char* data = NULL;
		if (this->_connection->readsize(static_cast<int>(size), &data) < 0 || data == NULL) {
			return -1;
		}
		// Verify BEFORE Write(): RocksDB appends the batch to the local WAL
		// ahead of memtable validation, so an unchecked corrupt batch can
		// poison this node's storage even though the write is rejected.
		if (has_crc) {
			uint32_t got_crc = util::crc32(0, reinterpret_cast<const uint8_t*>(data), static_cast<size_t>(size));
			if (got_crc != want_crc) {
				log_err("snapshot push: WAL tail batch CRC mismatch (lsn=%llu want=%u got=%u size=%llu) -> aborting before apply",
					(unsigned long long)lsn, want_crc, got_crc, (unsigned long long)size);
				delete[] data;
				rdb->incr_wal_sync_crc_mismatch();
				return -1;
			}
		}
		rocksdb::WriteBatch batch(string(data, size));
		if (rdb->apply_batch_with_lsn(batch, lsn) < 0) {
			log_err("snapshot push: failed to apply WAL batch (lsn=%llu)", (unsigned long long)lsn);
			delete[] data;
			return -1;
		}
		// forward the identical batch to each slave session (drop dead ones)
		for (size_t si = 0; si < slave_sessions.size(); si++) {
			if (!slave_sessions[si]) {
				continue;
			}
			char wline[96];
			uint32_t fwd_crc = util::crc32(0, reinterpret_cast<const uint8_t*>(data), static_cast<size_t>(size));
			snprintf(wline, sizeof(wline), "WBATCH %llu %llu %u\r\n",
				(unsigned long long)lsn, (unsigned long long)size, fwd_crc);
			if (slave_sessions[si]->write(wline, strlen(wline)) < 0
					|| slave_sessions[si]->write(data, static_cast<int>(size)) < 0) {
				log_warning("snapshot push: slave session %zu died while forwarding WAL tail -> dropping it (that slave stays diverged until its next reconstruction)", si);
				slave_sessions[si] = shared_connection();
			}
		}
		delete[] data;
		applied++;
	}
	// close out the slave sessions
	for (size_t si = 0; si < slave_sessions.size(); si++) {
		if (!slave_sessions[si]) {
			continue;
		}
		if (slave_sessions[si]->write("WEND\r\n", 6) < 0) {
			continue;
		}
		char* sp = NULL;
		if (slave_sessions[si]->readline(&sp) >= 0 && sp != NULL) {
			char sq[64];
			util::next_word(sp, sq, sizeof(sq));
			if (strcmp(sq, "STORED") != 0) {
				log_warning("snapshot push: slave session %zu did not confirm STORED", si);
			}
			delete[] sp;
		}
	}

	char line[64];
	snprintf(line, sizeof(line), "STORED %llu\r\n", (unsigned long long)applied);
	if (this->_connection->write(line, strlen(line)) < 0) {
		return -1;
	}
	log_notice("snapshot push complete (seq=%llu, wal_batches=%llu)",
		(unsigned long long)cp_seq, (unsigned long long)applied);
	return 0;
#else
	return this->_send_result(result_server_error, "not_compiled");
#endif
}

/**
 *	Fan the staged checkpoint out to this partition's Active slaves (relay
 *	hops). Each successful session has already verified + swapped its copy
 *	and is left OPEN, waiting for the WAL-tail WBATCH forwards; failures are
 *	logged and skipped (best-effort).
 */
int op_repl_snapshot_push::_relay_staging_to_slaves(const string& staging, uint64_t cp_seq,
		vector<shared_connection>& slave_sessions) {
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb == NULL) {
		return -1;
	}
	string self_key = this->_cluster->to_node_key(this->_cluster->get_server_name(), this->_cluster->get_server_port());

	// enumerate the staged files once
	vector<pair<string, uint64_t> > files;
	{
		DIR* d = opendir(staging.c_str());
		if (d == NULL) {
			return -1;
		}
		struct dirent* ent;
		while ((ent = readdir(d)) != NULL) {
			string fn = ent->d_name;
			if (fn == "." || fn == "..") {
				continue;
			}
			struct stat st;
			string child = staging + "/" + fn;
			if (stat(child.c_str(), &st) == 0 && S_ISREG(st.st_mode)) {
				files.push_back(make_pair(fn, static_cast<uint64_t>(st.st_size)));
			}
		}
		closedir(d);
	}

	char* buf = new char[kPushChunkBytes];
	vector<cluster::node> nodes = this->_cluster->get_node();
	for (vector<cluster::node>::iterator it = nodes.begin(); it != nodes.end(); it++) {
		if (it->node_role != cluster::role_slave
				|| it->node_partition != this->_partition
				|| it->node_state != cluster::state_active) {
			continue;
		}
		string skey = this->_cluster->to_node_key(it->node_server_name, it->node_server_port);
		if (skey == self_key) {
			continue;
		}
		shared_connection sc(new connection_tcp(it->node_server_name, it->node_server_port));
		if (sc->open() < 0) {
			log_warning("snapshot push relay: cannot connect to slave [%s] -> skipped (it stays diverged until its next reconstruction)", skey.c_str());
			continue;
		}
		char line[BUFSIZ];
		snprintf(line, sizeof(line), "repl_snapshot_push %d %d 0 relay=1", this->_partition, this->_partition_size);
		if (sc->writeline(line) < 0) {
			continue;
		}
		char* p = NULL;
		if (sc->readline(&p) < 0) {
			continue;
		}
		char q[BUFSIZ];
		util::next_word(p, q, sizeof(q));
		bool ok = (strcmp(q, "OK") == 0);
		if (!ok) {
			log_warning("snapshot push relay: slave [%s] declined (%s) -> skipped", skey.c_str(), p);
			delete[] p;
			continue;
		}
		delete[] p;

		int sr = 0;
		snprintf(line, sizeof(line), "SNAPSHOT %llu %s %zu\r\n",
			(unsigned long long)cp_seq, rdb->get_master_id().c_str(), files.size());
		if (sc->write(line, strlen(line)) < 0) {
			continue;
		}
		for (size_t i = 0; i < files.size() && sr == 0; i++) {
			const string& name = files[i].first;
			uint64_t size = files[i].second;
			string child = staging + "/" + name;
			uint32_t crc = 0;
			{
				FILE* cf = fopen(child.c_str(), "rb");
				if (cf == NULL) {
					sr = -1;
					break;
				}
				size_t got;
				while ((got = fread(buf, 1, kPushChunkBytes, cf)) > 0) {
					crc = util::crc32(crc, reinterpret_cast<const uint8_t*>(buf), got);
				}
				fclose(cf);
			}
			snprintf(line, sizeof(line), "FILE %s %llu %u\r\n", name.c_str(), (unsigned long long)size, crc);
			if (sc->write(line, strlen(line)) < 0) {
				sr = -1;
				break;
			}
			FILE* fp = fopen(child.c_str(), "rb");
			if (fp == NULL) {
				sr = -1;
				break;
			}
			uint64_t sent = 0;
			while (sent < size) {
				size_t want = static_cast<size_t>(min<uint64_t>(kPushChunkBytes, size - sent));
				size_t got = fread(buf, 1, want, fp);
				if (got == 0 || sc->write(buf, static_cast<int>(got)) < 0) {
					sr = -1;
					break;
				}
				sent += got;
			}
			fclose(fp);
		}
		if (sr < 0) {
			log_warning("snapshot push relay: streaming to slave [%s] failed -> skipped", skey.c_str());
			continue;
		}
		if (sc->write("END\r\n", 5) < 0) {
			continue;
		}
		if (sc->readline(&p) < 0) {
			continue;
		}
		util::next_word(p, q, sizeof(q));
		bool swapped = (strcmp(q, "SWAPPED") == 0);
		delete[] p;
		if (!swapped) {
			log_warning("snapshot push relay: slave [%s] did not confirm swap -> skipped", skey.c_str());
			continue;
		}
		log_notice("snapshot push relay: slave [%s] seeded (seq=%llu)", skey.c_str(), (unsigned long long)cp_seq);
		slave_sessions.push_back(sc);
	}
	delete[] buf;
	return 0;
#else
	return -1;
#endif
}

/**
 *	SOURCE side: push checkpoint + WAL tail to the destination cluster.
 */
int op_repl_snapshot_push::_run_client(int partition, int partition_size) {
#ifdef HAVE_LIBROCKSDB
	this->_client_result = client_result_error;
	if (this->_storage == NULL || this->_storage->get_type() != storage::type_rocksdb) {
		return -1;
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb == NULL) {
		return -1;
	}

	{
		char req[BUFSIZ];
		snprintf(req, sizeof(req), "repl_snapshot_push %d %d %llu",
			partition, partition_size, (unsigned long long)(rdb->get_snapshot_bwlimit() < 0 ? 0 : rdb->get_snapshot_bwlimit()));
		if (this->_connection->writeline(req) < 0) {
			return -1;
		}
	}

	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (strcmp(q, "REDIRECT") == 0) {
		n += util::next_word(p + n, q, sizeof(q));
		this->_redirect_host = q;
		util::next_word(p + n, q, sizeof(q));
		try {
			this->_redirect_port = boost::lexical_cast<int>(q);
		} catch (...) {
			this->_redirect_port = 0;
		}
		delete[] p;
		this->_client_result = client_result_redirect;
		return -1;
	}
	if (strcmp(q, "OK") != 0) {
		log_notice("snapshot push declined by destination (reply=%s)", p);
		delete[] p;
		this->_client_result = client_result_declined;
		return -1;
	}
	delete[] p;

	// PIN the WAL (and SSTs) for the whole push: the tail we must replay is
	// (checkpoint_seq, swap] and file streaming takes transfer-duration —
	// without the pin a small wal-ttl/size cap could purge that range
	// mid-transfer and strand the destination missing a write window.
	if (rdb->disable_file_deletions() < 0) {
		return -1;
	}
	int r = 0;
	string cp_path;
	uint64_t cp_seq = 0;
	do {
		if (rdb->create_snapshot_checkpoint(cp_path, cp_seq) < 0) {
			r = -1;
			break;
		}

		// enumerate checkpoint files
		vector<pair<string, uint64_t> > files;
		{
			DIR* d = opendir(cp_path.c_str());
			if (d == NULL) {
				r = -1;
				break;
			}
			struct dirent* ent;
			while ((ent = readdir(d)) != NULL) {
				string fn = ent->d_name;
				if (fn == "." || fn == "..") {
					continue;
				}
				struct stat st;
				string child = cp_path + "/" + fn;
				if (stat(child.c_str(), &st) == 0 && S_ISREG(st.st_mode)) {
					files.push_back(make_pair(fn, static_cast<uint64_t>(st.st_size)));
				}
			}
			closedir(d);
		}

		char line[BUFSIZ];
		snprintf(line, sizeof(line), "SNAPSHOT %llu %s %zu\r\n",
			(unsigned long long)cp_seq, rdb->get_master_id().c_str(), files.size());
		if (this->_connection->write(line, strlen(line)) < 0) {
			r = -1;
			break;
		}

		bwlimitter bw;
		bw.set_bwlimit(static_cast<uint64_t>(rdb->get_snapshot_bwlimit() < 0 ? 0 : rdb->get_snapshot_bwlimit()));

		char* buf = new char[kPushChunkBytes];
		for (size_t i = 0; i < files.size() && r == 0; i++) {
			const string& name = files[i].first;
			uint64_t size = files[i].second;
			string child = cp_path + "/" + name;

			uint32_t crc = 0;
			{
				FILE* cf = fopen(child.c_str(), "rb");
				if (cf == NULL) {
					r = -1;
					break;
				}
				size_t got;
				while ((got = fread(buf, 1, kPushChunkBytes, cf)) > 0) {
					crc = util::crc32(crc, reinterpret_cast<const uint8_t*>(buf), got);
				}
				fclose(cf);
			}

			snprintf(line, sizeof(line), "FILE %s %llu %u\r\n", name.c_str(), (unsigned long long)size, crc);
			if (this->_connection->write(line, strlen(line)) < 0) {
				r = -1;
				break;
			}
			FILE* fp = fopen(child.c_str(), "rb");
			if (fp == NULL) {
				r = -1;
				break;
			}
			uint64_t sent = 0;
			while (sent < size) {
				size_t want = static_cast<size_t>(min<uint64_t>(kPushChunkBytes, size - sent));
				size_t got = fread(buf, 1, want, fp);
				if (got == 0) {
					r = -1;
					break;
				}
				if (this->_connection->write(buf, static_cast<int>(got)) < 0) {
					r = -1;
					break;
				}
				sent += got;
				long sleep_usec = bw.sleep_for_bwlimit(got);
				if (sleep_usec > 0) {
					usleep(sleep_usec);
				}
			}
			fclose(fp);
		}
		delete[] buf;
		if (r < 0) {
			break;
		}
		if (this->_connection->write("END\r\n", 5) < 0) {
			r = -1;
			break;
		}

		// destination verifies + swaps before acknowledging
		if (this->_connection->readline(&p) < 0) {
			r = -1;
			break;
		}
		util::next_word(p, q, sizeof(q));
		bool swapped = (strcmp(q, "SWAPPED") == 0);
		delete[] p;
		if (!swapped) {
			log_warning("destination did not confirm swap -> aborting snapshot push", 0);
			r = -1;
			break;
		}

		// WAL tail: everything committed since the checkpoint. Reading it
		// AFTER the swap ack guarantees it covers every write whose live
		// duplicate landed on the destination before the swap (and was
		// therefore wiped by it). Later writes reach the destination through
		// the live duplicate stream against the NEW db.
		{
			vector<pair<uint64_t, rocksdb::WriteBatch> > updates;
			if (rdb->get_updates_since(cp_seq, updates) < 0) {
				log_err("failed to read WAL tail since checkpoint (seq=%llu) despite the deletion pin", (unsigned long long)cp_seq);
				r = -1;
				break;
			}
			for (size_t i = 0; i < updates.size() && r == 0; i++) {
				string data = updates[i].second.Data();
				// A batch corrupt at read time would CRC-match in transit;
				// refuse to stream it (destination keeps its dump fallback).
				if (!storage_rocksdb::validate_batch_rep(updates[i].second)) {
					log_err("snapshot push: WAL tail batch at LSN %llu failed structural validation -> aborting push",
						(unsigned long long)updates[i].first);
					r = -1;
					break;
				}
				// CRC-32 as a 3rd token (older receivers ignore it) — same
				// pre-apply integrity check as the WAL sync BATCH line.
				uint32_t wcrc = util::crc32(0, reinterpret_cast<const uint8_t*>(data.data()), data.size());
				snprintf(line, sizeof(line), "WBATCH %llu %zu %u\r\n",
					(unsigned long long)updates[i].first, data.size(), wcrc);
				if (this->_connection->write(line, strlen(line)) < 0
						|| this->_connection->write(data.data(), static_cast<int>(data.size())) < 0) {
					r = -1;
				}
			}
			if (r < 0) {
				break;
			}
			if (this->_connection->write("WEND\r\n", 6) < 0) {
				r = -1;
				break;
			}
			log_notice("snapshot push: streamed %zu WAL tail batch(es) since seq=%llu",
				updates.size(), (unsigned long long)cp_seq);
		}

		if (this->_connection->readline(&p) < 0) {
			r = -1;
			break;
		}
		util::next_word(p, q, sizeof(q));
		bool stored = (strcmp(q, "STORED") == 0);
		delete[] p;
		if (!stored) {
			r = -1;
			break;
		}
	} while (false);

	if (!cp_path.empty()) {
		rdb->remove_snapshot_checkpoint(cp_path);
	}
	rdb->enable_file_deletions();

	if (r == 0) {
		this->_client_result = client_result_success;
		log_notice("snapshot push succeeded (partition=%d, seq=%llu)", partition, (unsigned long long)cp_seq);
	}
	return r;
#else
	return -1;
#endif
}
// }}}

}	// namespace flare
}	// namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
