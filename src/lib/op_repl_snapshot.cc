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
 *	op_repl_snapshot.cc
 *
 *	implementation of gree::flare::op_repl_snapshot (see the header for the
 *	wire protocol and rationale)
 */
#include "op_repl_snapshot.h"
#include "bwlimitter.h"
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

// Stream files in bounded chunks so neither side ever materializes a whole
// SST in memory and the bandwidth throttle gets fine-grained sleep points.
static const size_t kSnapshotChunkBytes = 1024 * 1024;

// {{{ ctor/dtor
op_repl_snapshot::op_repl_snapshot(shared_connection c, storage* st):
		op(c, "repl_snapshot"),
		_storage(st),
		_bwlimit(0),
		_peer_bwlimit_request(0) {
}

op_repl_snapshot::~op_repl_snapshot() {
}
// }}}

// {{{ protected methods
int op_repl_snapshot::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	// Optional: the client's requested bandwidth cap in KB/s (0 = no
	// preference). The effective cap is min(server-configured, requested).
	// Unknown trailing tokens are ignored for forward compat.
	char q[BUFSIZ];
	util::next_word(p, q, sizeof(q));
	if (q[0]) {
		try {
			this->_peer_bwlimit_request = boost::lexical_cast<uint64_t>(q);
		} catch (...) {
			// ignore malformed value; keep server default
		}
	}
	delete[] p;
	return 0;
}

/**
 *	SERVER side (the reseed SOURCE): create a checkpoint, stream its files.
 */
int op_repl_snapshot::_run_server() {
#ifdef HAVE_LIBROCKSDB
	if (this->_storage == NULL || this->_storage->get_type() != storage::type_rocksdb) {
		return this->_send_result(result_server_error, "not_supported");
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb == NULL) {
		return this->_send_result(result_server_error, "internal_error");
	}

	string cp_path;
	uint64_t cp_seq = 0;
	if (rdb->create_snapshot_checkpoint(cp_path, cp_seq) < 0) {
		return this->_send_result(result_server_error, "checkpoint_failed");
	}

	// Enumerate the checkpoint's regular files (checkpoints are flat).
	vector<pair<string, uint64_t> > files;
	DIR* d = opendir(cp_path.c_str());
	if (d == NULL) {
		rdb->remove_snapshot_checkpoint(cp_path);
		return this->_send_result(result_server_error, "checkpoint_unreadable");
	}
	struct dirent* ent;
	while ((ent = readdir(d)) != NULL) {
		string n = ent->d_name;
		if (n == "." || n == "..") {
			continue;
		}
		struct stat st;
		string child = cp_path + "/" + n;
		if (stat(child.c_str(), &st) == 0 && S_ISREG(st.st_mode)) {
			files.push_back(make_pair(n, static_cast<uint64_t>(st.st_size)));
		}
	}
	closedir(d);

	char line[BUFSIZ];
	snprintf(line, sizeof(line), "SNAPSHOT %llu %s %zu\r\n",
		(unsigned long long)cp_seq, rdb->get_master_id().c_str(), files.size());
	if (this->_connection->write(line, strlen(line)) < 0) {
		rdb->remove_snapshot_checkpoint(cp_path);
		return -1;
	}

	// Never saturate the NIC against serving traffic: the SENDER throttles.
	// Effective cap = min(this node's rocksdb-snapshot-bwlimit — default
	// ~1/4 of a 1 Gbps link — and whatever the receiver asked for).
	uint64_t effective_kbps = static_cast<uint64_t>(rdb->get_snapshot_bwlimit() < 0 ? 0 : rdb->get_snapshot_bwlimit());
	if (this->_peer_bwlimit_request > 0
			&& (effective_kbps == 0 || this->_peer_bwlimit_request < effective_kbps)) {
		effective_kbps = this->_peer_bwlimit_request;
	}
	log_notice("snapshot stream bwlimit: %llu KB/s (server=%d, requested=%llu; 0=unlimited)",
		(unsigned long long)effective_kbps, rdb->get_snapshot_bwlimit(),
		(unsigned long long)this->_peer_bwlimit_request);
	bwlimitter bw;
	bw.set_bwlimit(effective_kbps);

	int r = 0;
	char* buf = new char[kSnapshotChunkBytes];
	for (size_t i = 0; i < files.size() && r == 0; i++) {
		const string& name = files[i].first;
		uint64_t size = files[i].second;

		snprintf(line, sizeof(line), "FILE %s %llu\r\n", name.c_str(), (unsigned long long)size);
		if (this->_connection->write(line, strlen(line)) < 0) {
			r = -1;
			break;
		}

		string child = cp_path + "/" + name;
		FILE* fp = fopen(child.c_str(), "rb");
		if (fp == NULL) {
			log_err("failed to open checkpoint file [%s]", child.c_str());
			r = -1;
			break;
		}
		uint64_t sent = 0;
		while (sent < size) {
			size_t want = static_cast<size_t>(min<uint64_t>(kSnapshotChunkBytes, size - sent));
			size_t got = fread(buf, 1, want, fp);
			if (got == 0) {
				log_err("short read streaming checkpoint file [%s] (sent=%llu size=%llu)",
					child.c_str(), (unsigned long long)sent, (unsigned long long)size);
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

	rdb->remove_snapshot_checkpoint(cp_path);

	if (r < 0) {
		// The stream is torn mid-file; the peer detects the short read and
		// falls back to the legacy dump. Nothing more we can send safely.
		return -1;
	}

	if (this->_connection->write("END\r\n", 5) < 0) {
		return -1;
	}
	log_notice("snapshot streamed to peer (files=%zu, seq=%llu)", files.size(), (unsigned long long)cp_seq);
	return 0;
#else
	return this->_send_result(result_server_error, "not_compiled");
#endif
}

int op_repl_snapshot::run_client() {
	if (this->_run_client() < 0) {
		return -1;
	}
	// No trailing result line beyond END; nothing else to parse.
	return 0;
}

/**
 *	CLIENT side (the reconstructing SLAVE): pull files, swap the DB in.
 */
int op_repl_snapshot::_run_client() {
#ifdef HAVE_LIBROCKSDB
	if (this->_storage == NULL || this->_storage->get_type() != storage::type_rocksdb) {
		return -1;
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (rdb == NULL) {
		return -1;
	}

	{
		char req[64];
		snprintf(req, sizeof(req), "repl_snapshot %llu", (unsigned long long)this->_bwlimit);
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
	if (strcmp(q, "SNAPSHOT") != 0) {
		log_warning("peer declined snapshot (reply=%s)", p);
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
	n += util::next_word(p + n, q, sizeof(q));		// master_id (informational; the
	string peer_master_id = q;						// authoritative copy is IN the files)
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

	log_notice("snapshot bootstrap: receiving %llu files (seq=%llu, source master_id=%s)",
		(unsigned long long)nfiles, (unsigned long long)cp_seq, peer_master_id.c_str());

	int r = 0;
	uint64_t received = 0;
	for (uint64_t i = 0; i < nfiles && r == 0; i++) {
		if (this->_connection->readline(&p) < 0) {
			r = -1;
			break;
		}
		n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "FILE") != 0) {
			log_err("snapshot stream desync (expected FILE, got [%s])", p);
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
		delete[] p;

		// Path-traversal guard: reject separators and dotfiles outright.
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
		while (got_total < size) {
			int want = static_cast<int>(min<uint64_t>(kSnapshotChunkBytes, size - got_total));
			char* data = NULL;
			if (this->_connection->readsize(want, &data) < 0 || data == NULL) {
				r = -1;
				break;
			}
			size_t written = fwrite(data, 1, want, fp);
			delete[] data;
			if (written != static_cast<size_t>(want)) {
				log_err("short write to staging file [%s]", child.c_str());
				r = -1;
				break;
			}
			got_total += want;
		}
		fclose(fp);
		received += got_total;
	}

	if (r == 0) {
		if (this->_connection->readline(&p) < 0) {
			r = -1;
		} else {
			util::next_word(p, q, sizeof(q));
			if (strcmp(q, "END") != 0) {
				log_err("snapshot stream missing END (got [%s])", p);
				r = -1;
			}
			delete[] p;
		}
	}

	if (r < 0) {
		log_warning("snapshot bootstrap failed mid-stream (received=%llu bytes) -> caller falls back to full dump",
			(unsigned long long)received);
		return -1;
	}

	if (rdb->swap_in_snapshot(staging, cp_seq) < 0) {
		return -1;
	}
	log_notice("snapshot bootstrap: swapped in %llu bytes, replication cursor at %llu",
		(unsigned long long)received, (unsigned long long)cp_seq);
	return 0;
#else
	return -1;
#endif
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
