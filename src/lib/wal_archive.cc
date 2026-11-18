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
 *	wal_archive.cc
 *
 *	implementation of gree::flare::wal_archive
 */
#include "wal_archive.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <deque>
#include <map>
#include <sstream>

#include <boost/lexical_cast.hpp>

#include <rocksdb/db.h>
#include <rocksdb/write_batch.h>

#include "connection_tcp.h"
#include "logger.h"
#include "storage_rocksdb.h"
#include "util.h"

namespace gree {
namespace flare {
namespace wal_archive {

namespace {

int64_t now_us() {
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return static_cast<int64_t>(tv.tv_sec) * 1000000 + tv.tv_usec;
}

// Whitespace-separated tokens of one line.
vector<string> tokens(const string& line) {
	vector<string> out;
	std::istringstream in(line);
	string t;
	while (in >> t) {
		out.push_back(t);
	}
	return out;
}

template <typename T>
bool parse_number(const string& s, T& out) {
	if (s.empty() || s[0] == '-' || s[0] == '+') {
		return false;
	}
	try {
		out = boost::lexical_cast<T>(s);
	} catch (boost::bad_lexical_cast&) {
		return false;
	}
	return true;
}

bool parse_signed(const string& s, int64_t& out) {
	if (s.empty()) {
		return false;
	}
	try {
		out = boost::lexical_cast<int64_t>(s);
	} catch (boost::bad_lexical_cast&) {
		return false;
	}
	return true;
}

// A token must be non-empty and free of whitespace to round-trip a line.
bool plain_token(const string& s) {
	if (s.empty()) {
		return false;
	}
	for (size_t i = 0; i < s.size(); i++) {
		if (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n' || s[i] == '=') {
			return false;
		}
	}
	return true;
}

bool write_all(int fd, const char* p, size_t n) {
	while (n > 0) {
		ssize_t w = ::write(fd, p, n);
		if (w < 0) {
			if (errno == EINTR) {
				continue;
			}
			return false;
		}
		p += w;
		n -= static_cast<size_t>(w);
	}
	return true;
}

bool fsync_dir(const string& dir) {
	int fd = open(dir.c_str(), O_RDONLY | O_DIRECTORY);
	if (fd < 0) {
		return false;
	}
	bool ok = fsync(fd) == 0;
	close(fd);
	return ok;
}

// Writes `content` to dir/name atomically (tmp + fsync + rename + dir fsync).
int write_file_atomically(const string& dir, const string& name, const string& content, string& err) {
	const string path = dir + "/" + name;
	const string tmp = path + ".tmp";
	int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		err = string("open ") + tmp + ": " + strerror(errno);
		return -1;
	}
	if (!write_all(fd, content.data(), content.size()) || fsync(fd) != 0) {
		err = string("write ") + tmp + ": " + strerror(errno);
		close(fd);
		unlink(tmp.c_str());
		return -1;
	}
	close(fd);
	if (rename(tmp.c_str(), path.c_str()) != 0) {
		err = string("rename ") + tmp + ": " + strerror(errno);
		unlink(tmp.c_str());
		return -1;
	}
	if (!fsync_dir(dir)) {
		err = string("fsync ") + dir + ": " + strerror(errno);
		return -1;
	}
	return 0;
}

int read_whole_file(const string& path, string& out) {
	FILE* f = fopen(path.c_str(), "rb");
	if (f == NULL) {
		return -1;
	}
	out.clear();
	char buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
		out.append(buf, n);
	}
	bool ok = ferror(f) == 0;
	fclose(f);
	return ok ? 0 : -1;
}

uint32_t crc_of(const string& data) {
	return util::crc32(0, reinterpret_cast<const uint8_t*>(data.data()), data.size());
}

// Accepts only the operations a physical replay reproduces exactly; anything
// else (Merge, DeleteRange, blob indexes, transaction markers) is refused.
class replayable_ops : public rocksdb::WriteBatch::Handler {
public:
	rocksdb::Status PutCF(uint32_t, const rocksdb::Slice&, const rocksdb::Slice&) override {
		return rocksdb::Status::OK();
	}
	rocksdb::Status DeleteCF(uint32_t, const rocksdb::Slice&) override {
		return rocksdb::Status::OK();
	}
	rocksdb::Status SingleDeleteCF(uint32_t, const rocksdb::Slice&) override {
		return rocksdb::Status::OK();
	}
	rocksdb::Status MergeCF(uint32_t, const rocksdb::Slice&, const rocksdb::Slice&) override {
		return rocksdb::Status::NotSupported("merge");
	}
	rocksdb::Status DeleteRangeCF(uint32_t, const rocksdb::Slice&, const rocksdb::Slice&) override {
		return rocksdb::Status::NotSupported("delete range");
	}
	void LogData(const rocksdb::Slice&) override {}
};

// Count of a raw WriteBatch, or false when it does not decode or holds an
// operation the replay does not reproduce.
bool decode_batch(const string& data, uint32_t& count) {
	if (data.size() < 12) {
		return false;
	}
	rocksdb::WriteBatch b(data);
	if (!storage_rocksdb::validate_batch_rep(b)) {
		return false;
	}
	replayable_ops ops;
	if (!b.Iterate(&ops).ok()) {
		return false;
	}
	count = b.Count();
	return true;
}

shared_connection bounded_connection(const string& host, int port) {
	connection_tcp* t = new connection_tcp(host, port);
	t->set_connect_timeout_ms(3000);
	t->set_connect_retry_limit(1);
	t->set_read_timeout(30000);
	return shared_connection(t);
}

// One line from the connection without its line ending; false on error.
bool read_line(shared_connection c, string& line) {
	char* p = NULL;
	if (c->readline(&p) < 0 || p == NULL) {
		return false;
	}
	line = p;
	delete[] p;
	while (!line.empty() && (line[line.size() - 1] == '\n' || line[line.size() - 1] == '\r')) {
		line.erase(line.size() - 1);
	}
	return true;
}

}	// namespace

// {{{ base marker
string format_base(const base& b) {
	std::ostringstream o;
	o << "FLAREBASE 1 seq=" << b.seq << " incarnation=" << b.id.incarnation
		<< " epoch=" << b.id.epoch << " master_id=" << b.id.master_id
		<< " time=" << b.time << "\n";
	return o.str();
}

int parse_base(const string& text, base& out) {
	string line = text.substr(0, text.find('\n'));
	vector<string> t = tokens(line);
	if (t.size() < 2 || t[0] != "FLAREBASE" || t[1] != "1") {
		return -1;
	}
	base b;
	b.seq = 0;
	b.time = 0;
	bool have_seq = false, have_time = false;
	for (size_t i = 2; i < t.size(); i++) {
		size_t eq = t[i].find('=');
		if (eq == string::npos) {
			return -1;
		}
		const string k = t[i].substr(0, eq), v = t[i].substr(eq + 1);
		if (k == "seq") {
			if (!parse_number(v, b.seq)) return -1;
			have_seq = true;
		} else if (k == "incarnation") {
			b.id.incarnation = v;
		} else if (k == "epoch") {
			b.id.epoch = v;
		} else if (k == "master_id") {
			b.id.master_id = v;
		} else if (k == "time") {
			if (!parse_signed(v, b.time)) return -1;
			have_time = true;
		}
		// unknown keys: forward compatibility
	}
	if (!have_seq || !have_time || !b.id.complete()) {
		return -1;
	}
	out = b;
	return 0;
}

int write_base_file(const string& dir, const base& b) {
	if (!b.id.complete() || !plain_token(b.id.incarnation) || !plain_token(b.id.epoch)
			|| !plain_token(b.id.master_id)) {
		return -1;
	}
	string err;
	if (write_file_atomically(dir, kBaseFileName, format_base(b), err) < 0) {
		log_err("could not write %s: %s", kBaseFileName, err.c_str());
		return -1;
	}
	return 0;
}

int read_base_file(const string& dir, base& out) {
	string text;
	if (read_whole_file(dir + "/" + kBaseFileName, text) < 0) {
		return -1;
	}
	return parse_base(text, out);
}
// }}}

// {{{ segment files
string segment_name(const vector<record>& records, int64_t close_time_ms) {
	char buf[128];
	const uint64_t first = records.empty() ? 0 : records.front().lsn;
	const uint64_t last = records.empty() ? 0 : records.back().last_lsn();
	snprintf(buf, sizeof(buf), "%020llu-%020llu-%013lld%s",
		(unsigned long long)first, (unsigned long long)last, (long long)close_time_ms, kSegmentSuffix);
	return buf;
}

int write_segment(const string& dir, const identity& id, const vector<record>& records,
		int64_t close_time_ms, string& out_path, string& err) {
	if (records.empty()) {
		err = "empty segment";
		return -1;
	}
	if (!plain_token(id.incarnation) || !plain_token(id.epoch) || !plain_token(id.master_id)) {
		err = "identity is incomplete";
		return -1;
	}
	string content;
	content += "FLAREWAL 1 " + id.incarnation + " " + id.epoch + " " + id.master_id + "\n";
	char line[256];
	for (size_t i = 0; i < records.size(); i++) {
		const record& r = records[i];
		snprintf(line, sizeof(line), "R %llu %u %lld %zu %u\n",
			(unsigned long long)r.lsn, r.count, (long long)r.time_us, r.data.size(), crc_of(r.data));
		content += line;
		content += r.data;
		content += "\n";
	}
	snprintf(line, sizeof(line), "END %zu %llu %llu\n", records.size(),
		(unsigned long long)records.front().lsn, (unsigned long long)records.back().last_lsn());
	content += line;
	const string name = segment_name(records, close_time_ms);
	if (write_file_atomically(dir, name, content, err) < 0) {
		return -1;
	}
	out_path = dir + "/" + name;
	return 0;
}

int read_segment(const string& path, identity& id, vector<record>& records, string& err) {
	string content;
	if (read_whole_file(path, content) < 0) {
		err = string("cannot read ") + path;
		return -1;
	}
	vector<record> out;
	size_t pos = 0;
	auto next_line = [&](string& line) -> bool {
		size_t nl = content.find('\n', pos);
		if (nl == string::npos) {
			return false;
		}
		line = content.substr(pos, nl - pos);
		pos = nl + 1;
		return true;
	};
	string line;
	if (!next_line(line)) {
		err = "no header";
		return -1;
	}
	vector<string> h = tokens(line);
	if (h.size() != 5 || h[0] != "FLAREWAL" || h[1] != "1") {
		err = "bad header";
		return -1;
	}
	identity got;
	got.incarnation = h[2];
	got.epoch = h[3];
	got.master_id = h[4];
	for (;;) {
		if (!next_line(line)) {
			err = "no trailer (incomplete segment)";
			return -1;
		}
		vector<string> t = tokens(line);
		if (!t.empty() && t[0] == "END") {
			size_t n = 0;
			if (t.size() != 4 || !parse_number(t[1], n) || n != out.size() || out.empty()) {
				err = "trailer does not match the records";
				return -1;
			}
			uint64_t first = 0, last = 0;
			if (!parse_number(t[2], first) || !parse_number(t[3], last)
					|| first != out.front().lsn || last != out.back().last_lsn()) {
				err = "trailer range does not match the records";
				return -1;
			}
			if (pos != content.size()) {
				err = "data after the trailer";
				return -1;
			}
			break;
		}
		record r;
		size_t size = 0;
		uint32_t crc = 0;
		if (t.size() != 6 || t[0] != "R" || !parse_number(t[1], r.lsn)
				|| !parse_number(t[2], r.count) || !parse_signed(t[3], r.time_us)
				|| !parse_number(t[4], size) || !parse_number(t[5], crc)) {
			err = "bad record line";
			return -1;
		}
		if (size > content.size() - pos || content.size() - pos - size < 1 || content[pos + size] != '\n') {
			err = "record runs past the end of the segment";
			return -1;
		}
		r.data = content.substr(pos, size);
		pos += size + 1;
		if (crc_of(r.data) != crc) {
			err = "record CRC mismatch";
			return -1;
		}
		uint32_t count = 0;
		if (!decode_batch(r.data, count) || count != r.count) {
			err = "record does not decode as the batch it claims";
			return -1;
		}
		if (!out.empty() && r.lsn != out.back().last_lsn() + 1) {
			err = "records inside the segment do not continue";
			return -1;
		}
		out.push_back(r);
	}
	id = got;
	records.swap(out);
	return 0;
}
// }}}

// {{{ replay planning
replay_plan plan_replay(uint64_t base_seq, const vector<record>& records, int64_t until_us) {
	vector<const record*> sorted;
	for (size_t i = 0; i < records.size(); i++) {
		if (records[i].count > 0) {
			sorted.push_back(&records[i]);
		}
	}
	std::stable_sort(sorted.begin(), sorted.end(),
		[](const record* a, const record* b) { return a->lsn < b->lsn; });

	replay_plan plan;
	uint64_t cursor = base_seq;
	plan.last_lsn = base_seq;
	for (size_t i = 0; i < sorted.size(); i++) {
		const record* r = sorted[i];
		if (r->last_lsn() <= cursor) {
			// Already covered. The same batch archived twice is fine; a
			// DIFFERENT batch at a planned position means two histories were
			// mixed, and nothing after it can be trusted.
			if (!plan.apply.empty() && r->lsn == plan.apply.back()->lsn
					&& r->data != plan.apply.back()->data) {
				plan.conflict = true;
				break;
			}
			continue;
		}
		if (r->lsn <= cursor) {
			// Straddles the position: a batch is atomic and the base is at a
			// batch boundary, so this is not this copy's history.
			plan.conflict = true;
			break;
		}
		if (until_us > 0 && r->time_us > until_us) {
			plan.stopped_by_until = true;
			break;
		}
		if (r->lsn != cursor + 1) {
			plan.gap = true;
			plan.gap_expected = cursor + 1;
			plan.gap_found = r->lsn;
			break;
		}
		plan.apply.push_back(r);
		cursor = r->last_lsn();
		plan.last_lsn = cursor;
		plan.last_time_us = r->time_us;
	}
	return plan;
}
// }}}

// {{{ follower
const char* const follower::kPositionFile = "position";
const char* const follower::kNeedsBaseFile = "needs-base";
const char* const follower::kSyncedFile = "synced";

follower::response_result follower::classify_server_error(const string& body) {
	vector<string> t = tokens(body);
	const string reason = t.empty() ? string("") : t[0];
	if (reason == "epoch_mismatch" || reason == "master_id_mismatch"
			|| reason == "lsn_purged" || reason == "lsn_ahead" || reason == "batch_too_large"
			|| reason == "identity_changed") {
		// The position can never be served by this source again (purged:
		// archiving fell behind the source's retention; there is no pin), or
		// the source is serving another history.
		return response_needs_base;
	}
	// restored_unverified, generations_unavailable, wal_read_error, ...: the
	// source cannot serve now; the position is still good.
	return response_retry;
}

follower::response_result follower::read_response(shared_connection c, const identity& id,
		uint64_t& cursor, vector<record>& out, bool& more, uint64_t& server_latest,
		string& reason) {
	// Nothing from a response is kept until its END: the source re-checks
	// its identity after the slice and sends an error instead of END when it
	// changed while the slice was read, and a slice cut short is not known
	// to be one copy's history either.
	more = false;
	bool saw_epoch = false;
	uint64_t position = cursor;
	vector<record> slice;
	string line;
	for (;;) {
		if (!read_line(c, line)) {
			reason = "connection_lost";
			return response_transport;
		}
		if (line == "END") {
			if (!saw_epoch) {
				reason = "no_epoch";
				return response_retry;
			}
			cursor = position;
			out.insert(out.end(), slice.begin(), slice.end());
			return response_ok;
		}
		if (line.compare(0, 12, "SERVER_ERROR") == 0) {
			string body = line.substr(12);
			while (!body.empty() && body[0] == ' ') body.erase(0, 1);
			vector<string> t = tokens(body);
			reason = t.empty() ? string("server_error") : t[0];
			return classify_server_error(body);
		}
		vector<string> t = tokens(line);
		if (t.empty()) {
			continue;
		}
		if (t[0] == "EPOCH") {
			if (t.size() < 3) {
				reason = "protocol_error";
				return response_transport;
			}
			parse_number(t[2], server_latest);
			if (t[1] != id.epoch) {
				reason = "epoch_changed";
				return response_needs_base;
			}
			if (t.size() < 5) {
				// A source that does not name its copy and lineage in the same
				// line cannot be bound to one: fail closed.
				reason = "source_without_identity";
				return response_retry;
			}
			if (t[3] != id.incarnation) {
				reason = "incarnation_changed";
				return response_needs_base;
			}
			if (t[4] != id.master_id) {
				reason = "master_id_changed";
				return response_needs_base;
			}
			saw_epoch = true;
			continue;
		}
		if (t[0] == "MORE") {
			more = true;
			continue;
		}
		if (t[0] != "LSN") {
			continue;
		}
		uint64_t lsn = 0;
		if (t.size() < 2 || !parse_number(t[1], lsn)) {
			reason = "protocol_error";
			return response_transport;
		}
		if (!saw_epoch) {
			reason = "no_epoch";
			return response_retry;
		}
		if (!read_line(c, line)) {
			reason = "connection_lost";
			return response_transport;
		}
		vector<string> b = tokens(line);
		size_t size = 0;
		uint32_t want_crc = 0;
		if (b.size() < 3 || b[0] != "BATCH" || !parse_number(b[1], size) || !parse_number(b[2], want_crc)
				|| size < 12 || size > (static_cast<size_t>(1) << 30)) {
			reason = "protocol_error";
			return response_transport;
		}
		char* data = NULL;
		if (c->readsize(static_cast<int>(size), &data) < 0 || data == NULL) {
			if (data) delete[] data;
			reason = "connection_lost";
			return response_transport;
		}
		record r;
		r.data.assign(data, size);
		delete[] data;
		if (!read_line(c, line)) {
			reason = "connection_lost";
			return response_transport;
		}
		if (crc_of(r.data) != want_crc) {
			// Transport corruption: nothing from this batch on is kept.
			reason = "crc_mismatch";
			return response_transport;
		}
		if (!decode_batch(r.data, r.count)) {
			// CRC-clean but not a batch replay can apply (unknown operation
			// or structure): this chain cannot be archived past it.
			reason = "unsupported_batch";
			return response_needs_base;
		}
		r.lsn = lsn;
		r.time_us = now_us();	// complete, CRC-verified receipt (the time-restore key)
		if (r.count == 0 || r.last_lsn() <= position) {
			continue;		// already archived
		}
		if (r.lsn != position + 1) {
			// The source checks this too (lsn_purged); never archive a hole.
			reason = "gap";
			return response_needs_base;
		}
		position = r.last_lsn();
		slice.push_back(r);
	}
}

follower::follower(const options& o): _o(o), _pending_bytes(0), _cursor(o.from_lsn), _synced_us(0) {
}

int follower::_close_segment(string& err) {
	if (this->_pending.empty()) {
		return 0;
	}
	string path;
	if (write_segment(this->_o.out_dir, this->_o.id, this->_pending, now_us() / 1000, path, err) < 0) {
		return -1;
	}
	log_info("closed WAL segment %s (%zu batches, %llu bytes)", path.c_str(), this->_pending.size(),
		(unsigned long long)this->_pending_bytes);
	this->_pending.clear();
	this->_pending_bytes = 0;
	this->_write_position();
	this->_note_synced();
	return 0;
}

/**
 *	SYNCED time: the latest moment t such that everything the source had at t
 *	is in a CLOSED segment. Only advanced while nothing is pending in memory;
 *	the driver turns it into the archive's RPO once the files are uploaded.
 */
void follower::_note_synced() {
	if (!this->_pending.empty()) {
		return;
	}
	int64_t t = 0;
	while (!this->_observed.empty() && this->_observed.front().second <= this->_cursor) {
		t = this->_observed.front().first;
		this->_observed.pop_front();
	}
	if (t <= this->_synced_us) {
		return;
	}
	this->_synced_us = t;
	std::ostringstream o;
	o << (t / 1000) << "\n";
	string err;
	if (write_file_atomically(this->_o.out_dir, kSyncedFile, o.str(), err) < 0) {
		log_warning("could not record the synced time: %s", err.c_str());
	}
}

void follower::_write_position() {
	std::ostringstream o;
	o << this->_o.id.incarnation << " " << this->_o.id.epoch << " " << this->_o.id.master_id
		<< " " << this->_cursor << " " << (now_us() / 1000000) << "\n";
	string err;
	if (write_file_atomically(this->_o.out_dir, kPositionFile, o.str(), err) < 0) {
		log_warning("could not record the archive position: %s", err.c_str());
	}
}

int follower::run(volatile sig_atomic_t* stop) {
	if (this->_o.host.empty() || this->_o.port <= 0 || !this->_o.id.complete()
			|| this->_o.out_dir.empty() || this->_o.segment_seconds <= 0) {
		return exit_usage;
	}
	this->_write_position();
	const int64_t segment_us = static_cast<int64_t>(this->_o.segment_seconds) * 1000000;
	auto due = [&]() -> bool {
		return !this->_pending.empty()
			&& (now_us() - this->_pending.front().time_us >= segment_us
				|| this->_pending_bytes >= this->_o.segment_bytes);
	};
	// Sleeps up to `usec`, closing a due segment on the way; false on stop or
	// a segment that could not be written.
	int io_failed = 0;
	auto wait = [&](int64_t usec) -> bool {
		const int64_t until = now_us() + usec;
		while (!*stop) {
			if (due()) {
				string err;
				if (this->_close_segment(err) < 0) {
					log_err("could not write a WAL segment: %s", err.c_str());
					io_failed = 1;
					return false;
				}
			}
			const int64_t left = until - now_us();
			if (left <= 0) {
				return true;
			}
			usleep(static_cast<useconds_t>(left < 100000 ? left : 100000));
		}
		return false;
	};

	int backoff = 1;
	string last_reason;
	while (!*stop) {
		shared_connection c(bounded_connection(this->_o.host, this->_o.port));
		response_result rr = response_transport;
		string reason = "peer_unreachable";
		bool more = false;
		if (c->open() >= 0) {
			char req[BUFSIZ];
			snprintf(req, sizeof(req), "repl_sync_wal %llu %s %s %llu %llu%s",
				(unsigned long long)this->_cursor, this->_o.id.master_id.c_str(),
				this->_o.id.epoch.c_str(), (unsigned long long)this->_o.max_batches,
				(unsigned long long)this->_o.max_bytes, line_delimiter);
			const int64_t asked_us = now_us();
			if (c->write(req, strlen(req)) >= 0) {
				vector<record> got;
				uint64_t latest = 0;
				rr = read_response(c, this->_o.id, this->_cursor, got, more, latest, reason);
				for (size_t i = 0; i < got.size(); i++) {
					this->_pending_bytes += got[i].data.size();
					this->_pending.push_back(got[i]);
				}
				if (rr == response_ok && latest > 0) {
					// Everything the source had acknowledged when it was asked
					// is at or before `latest`.
					this->_observed.push_back(std::make_pair(asked_us, latest));
					this->_note_synced();
				}
			}
			c->close();
		}
		if (rr == response_needs_base) {
			// What was received is valid up to the cursor: keep it.
			string err;
			if (this->_close_segment(err) < 0) {
				log_err("could not write a WAL segment: %s", err.c_str());
				return exit_io;
			}
			std::ostringstream o;
			o << reason << " " << this->_cursor << " " << (now_us() / 1000000) << "\n";
			write_file_atomically(this->_o.out_dir, kNeedsBaseFile, o.str(), err);
			log_warning("WAL archive cannot continue this chain (%s at %llu): a new base is needed",
				reason.c_str(), (unsigned long long)this->_cursor);
			return exit_needs_base;
		}
		if (rr == response_ok) {
			backoff = 1;
			if (!last_reason.empty()) {
				log_notice("WAL archive following again (was: %s)", last_reason.c_str());
				last_reason.clear();
			}
			if (!wait(more ? 0 : this->_o.poll_usec)) {
				break;
			}
			continue;
		}
		if (reason != last_reason) {
			log_warning("WAL archive: %s (retrying, position %llu kept)", reason.c_str(),
				(unsigned long long)this->_cursor);
			last_reason = reason;
		}
		if (!wait(static_cast<int64_t>(backoff) * 1000000)) {
			break;
		}
		backoff = backoff < 30 ? backoff * 2 : 30;
	}
	if (io_failed) {
		return exit_io;
	}
	string err;
	if (this->_close_segment(err) < 0) {
		log_err("could not write the last WAL segment: %s", err.c_str());
		return exit_io;
	}
	return exit_ok;
}
// }}}

// {{{ replay
int replay(const string& db_dir, const string& seg_dir, int64_t until_us, FILE* report) {
	base b;
	if (read_base_file(db_dir, b) < 0) {
		fprintf(report, "replay error=no_base dir=%s\n", db_dir.c_str());
		return 3;
	}

	vector<string> names;
	DIR* d = opendir(seg_dir.c_str());
	if (d != NULL) {
		struct dirent* e;
		while ((e = readdir(d)) != NULL) {
			const string n = e->d_name;
			const size_t sl = strlen(kSegmentSuffix);
			if (n.size() > sl && n.compare(n.size() - sl, sl, kSegmentSuffix) == 0) {
				names.push_back(n);
			}
		}
		closedir(d);
	}
	std::sort(names.begin(), names.end());

	vector<record> all;
	int foreign = 0, corrupt = 0, used = 0;
	for (size_t i = 0; i < names.size(); i++) {
		identity id;
		vector<record> rs;
		string err;
		if (read_segment(seg_dir + "/" + names[i], id, rs, err) < 0) {
			// Not applied; the plan stops at the hole it leaves.
			log_err("WAL segment %s refused: %s", names[i].c_str(), err.c_str());
			corrupt++;
			continue;
		}
		if (id != b.id) {
			foreign++;
			continue;
		}
		used++;
		all.insert(all.end(), rs.begin(), rs.end());
	}

	rocksdb::Options opt;
	opt.create_if_missing = false;
	vector<string> cfs;
	rocksdb::Status ls = rocksdb::DB::ListColumnFamilies(rocksdb::DBOptions(opt), db_dir, &cfs);
	if (!ls.ok() || cfs.empty()) {
		fprintf(report, "replay error=open (%s)\n", ls.ToString().c_str());
		return 1;
	}
	vector<rocksdb::ColumnFamilyDescriptor> desc;
	for (size_t i = 0; i < cfs.size(); i++) {
		desc.push_back(rocksdb::ColumnFamilyDescriptor(cfs[i], rocksdb::ColumnFamilyOptions(opt)));
	}
	vector<rocksdb::ColumnFamilyHandle*> handles;
	rocksdb::DB* db = NULL;
	rocksdb::Status s = rocksdb::DB::Open(rocksdb::DBOptions(opt), db_dir, desc, &handles, &db);
	if (!s.ok() || db == NULL) {
		fprintf(report, "replay error=open (%s)\n", s.ToString().c_str());
		return 1;
	}
	auto close_db = [&]() {
		for (size_t i = 0; i < handles.size(); i++) {
			db->DestroyColumnFamilyHandle(handles[i]);
		}
		handles.clear();
		delete db;
		db = NULL;
	};

	// RESUME RULE. The database must be exactly the base, or a replay of THIS
	// chain that stopped part way. The sequence number alone cannot tell the
	// second case from a database written by something else, so every batch
	// is first recorded in a durable journal (the base and identity it
	// belongs to, and each batch's range and CRC) BEFORE it is written; a
	// re-run continues only when every batch the database already holds past
	// the base is in that journal with the same range and CRC as the plan.
	const uint64_t latest = db->GetLatestSequenceNumber();
	replay_plan plan = plan_replay(b.seq, all, until_us);
	const string journal_path = db_dir + "/" + kReplayJournalFileName;
	const string journal_header = string("FLAREREPLAY 1 ") + format_base(b);
	size_t start = 0;
	if (latest != b.seq) {
		string text;
		map<uint64_t, string> journal;	// lsn -> "<last> <crc>"
		bool header_ok = false;
		if (read_whole_file(journal_path, text) == 0) {
			std::istringstream in(text);
			string line;
			if (std::getline(in, line) && line + "\n" == journal_header) {
				header_ok = true;
				while (std::getline(in, line)) {
					vector<string> t = tokens(line);
					uint64_t lsn = 0;
					if (t.size() == 4 && t[0] == "B" && parse_number(t[1], lsn)) {
						journal[lsn] = t[2] + " " + t[3];
					}
				}
			}
		}
		bool found = false;
		for (size_t i = 0; header_ok && i < plan.apply.size(); i++) {
			const record* r = plan.apply[i];
			std::ostringstream want;
			want << r->last_lsn() << " " << crc_of(r->data);
			map<uint64_t, string>::const_iterator j = journal.find(r->lsn);
			if (j == journal.end() || j->second != want.str()) {
				break;
			}
			if (r->last_lsn() == latest) {
				start = i + 1;
				found = true;
				break;
			}
		}
		if (!found) {
			fprintf(report, "replay error=base_mismatch base_seq=%llu db_seq=%llu journal=%s\n",
				(unsigned long long)b.seq, (unsigned long long)latest, header_ok ? "differs" : "absent");
			close_db();
			return 3;
		}
	} else {
		string err;
		if (write_file_atomically(db_dir, kReplayJournalFileName, journal_header, err) < 0) {
			fprintf(report, "replay error=journal (%s)\n", err.c_str());
			close_db();
			return 1;
		}
	}

	int jfd = open(journal_path.c_str(), O_WRONLY | O_APPEND);
	if (jfd < 0) {
		fprintf(report, "replay error=journal (%s)\n", strerror(errno));
		close_db();
		return 1;
	}
	rocksdb::WriteOptions wo;
	size_t applied = 0;
	const size_t chunk = 256;
	for (size_t i = start; i < plan.apply.size(); i += chunk) {
		const size_t end = std::min(plan.apply.size(), i + chunk);
		string intent;
		char line[128];
		for (size_t k = i; k < end; k++) {
			const record* r = plan.apply[k];
			snprintf(line, sizeof(line), "B %llu %llu %u\n", (unsigned long long)r->lsn,
				(unsigned long long)r->last_lsn(), crc_of(r->data));
			intent += line;
		}
		if (!write_all(jfd, intent.data(), intent.size()) || fsync(jfd) != 0) {
			fprintf(report, "replay error=journal (%s)\n", strerror(errno));
			close(jfd);
			close_db();
			return 1;
		}
		for (size_t k = i; k < end; k++) {
			const record* r = plan.apply[k];
			rocksdb::WriteBatch wb(r->data);
			rocksdb::Status ws = db->Write(wo, &wb);
			if (!ws.ok()) {
				// An unknown column family lands here too: fail closed.
				fprintf(report, "replay error=write lsn=%llu (%s)\n", (unsigned long long)r->lsn, ws.ToString().c_str());
				close(jfd);
				close_db();
				return 1;
			}
			if (db->GetLatestSequenceNumber() != r->last_lsn()) {
				fprintf(report, "replay error=sequence lsn=%llu expected=%llu got=%llu\n",
					(unsigned long long)r->lsn, (unsigned long long)r->last_lsn(),
					(unsigned long long)db->GetLatestSequenceNumber());
				close(jfd);
				close_db();
				return 1;
			}
			applied++;
		}
	}
	close(jfd);
	rocksdb::Status fs = db->FlushWAL(true);
	close_db();
	if (!fs.ok()) {
		fprintf(report, "replay error=flush (%s)\n", fs.ToString().c_str());
		return 1;
	}
	fprintf(report, "replay base_seq=%llu applied=%zu last_lsn=%llu last_time_us=%lld base_time=%lld"
		" gap=%d gap_expected=%llu gap_found=%llu until=%d conflict=%d segments=%d foreign=%d corrupt=%d\n",
		(unsigned long long)b.seq, applied, (unsigned long long)plan.last_lsn,
		(long long)plan.last_time_us, (long long)b.time,
		plan.gap ? 1 : 0, (unsigned long long)plan.gap_expected, (unsigned long long)plan.gap_found,
		plan.stopped_by_until ? 1 : 0, plan.conflict ? 1 : 0, used, foreign, corrupt);
	return 0;
}
// }}}

}	// namespace wal_archive
}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
