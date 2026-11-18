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

#include "app.h"
#include "connection_tcp.h"
#include "stats.h"
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

/**
 *	STREAMING segment reader: one record in memory at a time, every check of
 *	the whole-file reader (header, CRC, decode, continuity, trailer, nothing
 *	after it). A segment that fails any of them is an error at the record
 *	where it fails; a caller that must not act on a bad segment validates it
 *	to the end first.
 */
segment_reader::segment_reader(): _f(NULL), _n(0), _first(0), _end(0), _done(false) {
}

segment_reader::~segment_reader() {
	this->close();
}

void segment_reader::close() {
	if (this->_f != NULL) {
		fclose(this->_f);
		this->_f = NULL;
	}
}

bool segment_reader::_line(string& line) {
	line.clear();
	for (;;) {
		int c = fgetc(this->_f);
		if (c == EOF) {
			return false;
		}
		if (c == '\n') {
			return true;
		}
		if (line.size() >= 512) {
			return false;		// no line of this format is that long
		}
		line += static_cast<char>(c);
	}
}

int segment_reader::open(const string& path, identity& id, string& err) {
	this->close();
	this->_n = 0;
	this->_first = this->_end = 0;
	this->_done = false;
	this->_f = fopen(path.c_str(), "rb");
	if (this->_f == NULL) {
		err = string("cannot read ") + path;
		return -1;
	}
	string line;
	if (!this->_line(line)) {
		err = "no header";
		return -1;
	}
	vector<string> h = tokens(line);
	if (h.size() != 5 || h[0] != "FLAREWAL" || h[1] != "1") {
		err = "bad header";
		return -1;
	}
	id.incarnation = h[2];
	id.epoch = h[3];
	id.master_id = h[4];
	return 0;
}

int segment_reader::next(record& r, string& err) {
	if (this->_f == NULL || this->_done) {
		return 0;
	}
	string line;
	if (!this->_line(line)) {
		err = "no trailer (incomplete segment)";
		return -1;
	}
	vector<string> t = tokens(line);
	if (!t.empty() && t[0] == "END") {
		size_t n = 0;
		uint64_t first = 0, last = 0;
		if (t.size() != 4 || !parse_number(t[1], n) || n != this->_n || this->_n == 0) {
			err = "trailer does not match the records";
			return -1;
		}
		if (!parse_number(t[2], first) || !parse_number(t[3], last) || first != this->_first || last != this->_end) {
			err = "trailer range does not match the records";
			return -1;
		}
		if (fgetc(this->_f) != EOF) {
			err = "data after the trailer";
			return -1;
		}
		this->_done = true;
		return 0;
	}
	size_t size = 0;
	uint32_t crc = 0;
	if (t.size() != 6 || t[0] != "R" || !parse_number(t[1], r.lsn)
			|| !parse_number(t[2], r.count) || !parse_signed(t[3], r.time_us)
			|| !parse_number(t[4], size) || !parse_number(t[5], crc) || size > (static_cast<size_t>(1) << 30)) {
		err = "bad record line";
		return -1;
	}
	r.data.resize(size);
	if (size > 0 && fread(&r.data[0], 1, size, this->_f) != size) {
		err = "record runs past the end of the segment";
		return -1;
	}
	if (fgetc(this->_f) != '\n') {
		err = "record runs past the end of the segment";
		return -1;
	}
	if (crc_of(r.data) != crc) {
		err = "record CRC mismatch";
		return -1;
	}
	uint32_t count = 0;
	if (!decode_batch(r.data, count) || count != r.count) {
		err = "record does not decode as the batch it claims";
		return -1;
	}
	if (this->_n > 0 && r.lsn != this->_end + 1) {
		err = "records inside the segment do not continue";
		return -1;
	}
	if (this->_n == 0) {
		this->_first = r.lsn;
	}
	this->_end = r.last_lsn();
	this->_n++;
	return 1;
}

int read_segment(const string& path, identity& id, vector<record>& records, string& err) {
	segment_reader sr;
	identity got;
	if (sr.open(path, got, err) < 0) {
		return -1;
	}
	vector<record> out;
	for (;;) {
		record r;
		int k = sr.next(r, err);
		if (k < 0) {
			return -1;
		}
		if (k == 0) {
			break;
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
	// `flared --wal-archive-follow` runs without the server's start-up, and
	// connection_tcp counts every byte into the process-wide stats: without
	// one the first read is a NULL dereference (CI 44299609676: the follower
	// died on its first slice and was restarted every second).
	if (stats_object == NULL) {
		stats_object = new stats();
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
namespace {

struct seg_info {
	string		name;
	uint64_t	first;
	uint64_t	last;
};

// The journal of a replay that may be continued: read one line at a time.
struct journal_reader {
	FILE*	f;
	long	offset;		// byte offset after the last line returned
	journal_reader(): f(NULL), offset(0) {}
	~journal_reader() { if (f) fclose(f); }
	bool line(string& out) {
		out.clear();
		int c;
		while ((c = fgetc(f)) != EOF) {
			if (c == '\n') {
				offset = ftell(f);
				return true;
			}
			out += static_cast<char>(c);
		}
		return false;
	}
};

}	// namespace

/**
 *	STREAMING REPLAY. The memory used does not grow with the archive: segments
 *	are validated one at a time (pass 1 keeps only their ranges), then read
 *	again one record at a time and applied (pass 2); a re-run checks its
 *	journal line by line. What is held at once: one record being decided, the
 *	last applied record (to compare a duplicate of it), one chunk of intents
 *	(<= 256 batches or 16 MiB), and a second reader on the previous segment
 *	when a segment overlaps it.
 *
 *	Order and rules are those of plan_replay: valid segments of this base's
 *	identity in sequence order; a record already covered must be the SAME
 *	batch as the one applied there (else conflict) — checked against the last
 *	applied record or, for an overlap, by reading the previous segment again;
 *	an overlap reaching further back than the previous segment cannot be
 *	checked and is a conflict (fail closed).
 */
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

	// pass 1: validate every segment to its trailer; keep only its range
	vector<seg_info> segs;
	vector<string> corrupt_names;
	int foreign = 0;
	for (size_t i = 0; i < names.size(); i++) {
		segment_reader sr;
		identity id;
		string err;
		seg_info si;
		si.name = names[i];
		si.first = si.last = 0;
		int k = sr.open(seg_dir + "/" + names[i], id, err);
		bool any = false;
		while (k == 0) {
			record r;
			k = sr.next(r, err);
			if (k == 1) {
				if (!any) si.first = r.lsn;
				si.last = r.last_lsn();
				any = true;
				k = 0;
			} else if (k == 0) {
				break;
			}
		}
		if (k < 0 || !any) {
			// Not applied. Whether it costs data is judged against what was
			// replayed (its name says which sequence numbers it held).
			log_err("WAL segment %s refused: %s", names[i].c_str(), err.c_str());
			corrupt_names.push_back(names[i]);
			continue;
		}
		if (id != b.id) {
			foreign++;
			continue;
		}
		segs.push_back(si);
	}
	std::stable_sort(segs.begin(), segs.end(),
		[](const seg_info& x, const seg_info& y) { return x.first < y.first; });

	rocksdb::Options opt;
	opt.create_if_missing = false;
	// bounded memtables: the replay writes the whole chain through them
	opt.write_buffer_size = 16 << 20;
	opt.max_write_buffer_number = 2;
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
	int jfd = -1;
	auto close_db = [&]() {
		if (jfd >= 0) {
			close(jfd);
			jfd = -1;
		}
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
	// re-run continues only when the batches the database already holds past
	// the base are, in order, the journal's lines with the same range and
	// CRC. The journal is then cut after the last of them (a chunk recorded
	// but not written is recorded again).
	const uint64_t latest = db->GetLatestSequenceNumber();
	const string journal_path = db_dir + "/" + kReplayJournalFileName;
	const string journal_header = string("FLAREREPLAY 1 ") + format_base(b);
	const bool resuming = latest != b.seq;
	journal_reader jr;
	bool header_ok = false;
	if (resuming) {
		jr.f = fopen(journal_path.c_str(), "rb");
		string line;
		if (jr.f != NULL && jr.line(line) && line + "\n" == journal_header) {
			header_ok = true;
		}
		if (!header_ok) {
			fprintf(report, "replay error=base_mismatch base_seq=%llu db_seq=%llu journal=%s\n",
				(unsigned long long)b.seq, (unsigned long long)latest, jr.f != NULL ? "differs" : "absent");
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
		jfd = open(journal_path.c_str(), O_WRONLY | O_APPEND);
		if (jfd < 0) {
			fprintf(report, "replay error=journal (%s)\n", strerror(errno));
			close_db();
			return 1;
		}
	}
	bool verifying = resuming;			// walking batches the database already holds

	replay_plan plan;					// the outcome (apply stays empty: nothing is held)
	plan.last_lsn = b.seq;
	uint64_t cursor = b.seq;
	record last_applied;
	bool have_last = false;
	size_t applied = 0;
	vector<record> chunk;
	size_t chunk_bytes = 0;
	string fail;						// a hard error (exit 1/3) found on the way
	int fail_rc = 0;
	rocksdb::WriteOptions wo;

	auto flush_chunk = [&]() -> bool {
		if (chunk.empty()) {
			return true;
		}
		string intent;
		char line[128];
		for (size_t k = 0; k < chunk.size(); k++) {
			snprintf(line, sizeof(line), "B %llu %llu %u\n", (unsigned long long)chunk[k].lsn,
				(unsigned long long)chunk[k].last_lsn(), crc_of(chunk[k].data));
			intent += line;
		}
		if (!write_all(jfd, intent.data(), intent.size()) || fsync(jfd) != 0) {
			fail = string("journal (") + strerror(errno) + ")";
			fail_rc = 1;
			return false;
		}
		for (size_t k = 0; k < chunk.size(); k++) {
			const record& r = chunk[k];
			rocksdb::WriteBatch wb(r.data);
			rocksdb::Status ws = db->Write(wo, &wb);
			if (!ws.ok()) {
				// An unknown column family lands here too: fail closed.
				fail = "write lsn=" + boost::lexical_cast<string>(r.lsn) + " (" + ws.ToString() + ")";
				fail_rc = 1;
				return false;
			}
			if (db->GetLatestSequenceNumber() != r.last_lsn()) {
				fail = "sequence lsn=" + boost::lexical_cast<string>(r.lsn) + " expected="
					+ boost::lexical_cast<string>(r.last_lsn()) + " got="
					+ boost::lexical_cast<string>(db->GetLatestSequenceNumber());
				fail_rc = 1;
				return false;
			}
			applied++;
		}
		chunk.clear();
		chunk_bytes = 0;
		return true;
	};

	// A batch that continues the chain: checked against the journal while
	// the database already holds it, applied after that.
	auto take = [&](const record& r) -> bool {
		if (verifying) {
			string line;
			char want[128];
			snprintf(want, sizeof(want), "B %llu %llu %u", (unsigned long long)r.lsn,
				(unsigned long long)r.last_lsn(), crc_of(r.data));
			if (r.last_lsn() > latest || !jr.line(line) || line != want) {
				fail = "base_mismatch base_seq=" + boost::lexical_cast<string>(b.seq) + " db_seq="
					+ boost::lexical_cast<string>(latest) + " journal=differs";
				fail_rc = 3;
				return false;
			}
			if (r.last_lsn() == latest) {
				// the database holds exactly up to here: cut the journal after
				// this line and continue appending
				fclose(jr.f);
				jr.f = NULL;
				if (truncate(journal_path.c_str(), jr.offset) != 0
						|| (jfd = open(journal_path.c_str(), O_WRONLY | O_APPEND)) < 0) {
					fail = string("journal (") + strerror(errno) + ")";
					fail_rc = 1;
					return false;
				}
				verifying = false;
			}
			return true;
		}
		chunk.push_back(r);
		chunk_bytes += r.data.size();
		if (chunk.size() >= 256 || chunk_bytes >= (16u << 20)) {
			return flush_chunk();
		}
		return true;
	};

	bool stop = false;
	for (size_t si = 0; si < segs.size() && !stop && fail_rc == 0; si++) {
		if (segs[si].last <= cursor && segs[si].last <= b.seq) {
			continue;						// wholly before the base
		}
		segment_reader sr;
		identity id;
		string err;
		if (sr.open(seg_dir + "/" + segs[si].name, id, err) < 0) {
			fail = "segment " + segs[si].name + " changed during the replay: " + err;
			fail_rc = 1;
			break;
		}
		// the previous applied segment, read again to check an overlap
		segment_reader prev;
		record prev_rec;
		bool prev_open = false, prev_have = false;
		const size_t prev_idx = si > 0 ? si - 1 : 0;
		for (;;) {
			record r;
			int k = sr.next(r, err);
			if (k < 0) {
				fail = "segment " + segs[si].name + " changed during the replay: " + err;
				fail_rc = 1;
				break;
			}
			if (k == 0) {
				break;
			}
			if (r.count == 0) {
				continue;
			}
			if (r.last_lsn() <= cursor) {
				// covered: must be the batch applied (or held) there
				if (r.last_lsn() <= b.seq) {
					continue;				// before the base
				}
				bool same;
				if (have_last && r.lsn == last_applied.lsn) {
					same = r.data == last_applied.data;
				} else if (si > 0 && r.lsn >= segs[prev_idx].first && r.last_lsn() <= segs[prev_idx].last) {
					if (!prev_open) {
						identity pid;
						string perr;
						prev_open = prev.open(seg_dir + "/" + segs[prev_idx].name, pid, perr) == 0;
					}
					while (prev_open && (!prev_have || prev_rec.lsn < r.lsn)) {
						string perr;
						int pk = prev.next(prev_rec, perr);
						if (pk != 1) {
							prev_open = false;
							break;
						}
						prev_have = true;
					}
					same = prev_have && prev_rec.lsn == r.lsn && prev_rec.data == r.data;
				} else {
					same = false;			// an overlap that cannot be checked
				}
				if (!same) {
					plan.conflict = true;
					stop = true;
					break;
				}
				continue;
			}
			if (r.lsn <= cursor) {
				plan.conflict = true;		// straddles: not this copy's history
				stop = true;
				break;
			}
			if (until_us > 0 && r.time_us > until_us) {
				plan.stopped_by_until = true;
				stop = true;
				break;
			}
			if (r.lsn != cursor + 1) {
				plan.gap = true;
				plan.gap_expected = cursor + 1;
				plan.gap_found = r.lsn;
				stop = true;
				break;
			}
			if (!take(r)) {
				break;
			}
			cursor = r.last_lsn();
			plan.last_lsn = cursor;
			plan.last_time_us = r.time_us;
			last_applied = r;
			have_last = true;
		}
	}
	if (fail_rc == 0 && verifying) {
		// the archive ended (or stopped) before the database's position
		fail = "base_mismatch base_seq=" + boost::lexical_cast<string>(b.seq) + " db_seq="
			+ boost::lexical_cast<string>(latest) + " journal=differs";
		fail_rc = 3;
	}
	if (fail_rc == 0) {
		flush_chunk();
	}
	if (fail_rc != 0) {
		fprintf(report, "replay error=%s\n", fail.c_str());
		close_db();
		return fail_rc;
	}
	rocksdb::Status fs = db->FlushWAL(true);
	close_db();
	if (!fs.ok()) {
		fprintf(report, "replay error=flush (%s)\n", fs.ToString().c_str());
		return 1;
	}
	// COMPLETENESS. A refused segment that held sequence numbers past what
	// was replayed is archived history this restore does not reach: with the
	// last segment corrupt there is no gap to show for it. (One whose range
	// is covered — a duplicate — costs nothing; one past a time bound that
	// already stopped the replay is not wanted.) A gap or a conflict is the
	// same: the archive holds more than was replayed.
	int corrupt_beyond = 0;
	for (size_t i = 0; i < corrupt_names.size(); i++) {
		unsigned long long first = 0, last = 0;
		long long ms = 0;
		if (sscanf(corrupt_names[i].c_str(), "%llu-%llu-%lld", &first, &last, &ms) != 3) {
			corrupt_beyond++;		// cannot tell what it held: assume the worst
			continue;
		}
		if (last <= plan.last_lsn) {
			continue;
		}
		if (plan.stopped_by_until && first > plan.last_lsn) {
			continue;
		}
		corrupt_beyond++;
	}
	const bool complete = !plan.gap && !plan.conflict && corrupt_beyond == 0;
	fprintf(report, "replay base_seq=%llu applied=%zu last_lsn=%llu last_time_us=%lld base_time=%lld"
		" gap=%d gap_expected=%llu gap_found=%llu until=%d conflict=%d segments=%zu foreign=%d corrupt=%zu"
		" corrupt_beyond=%d complete=%d\n",
		(unsigned long long)b.seq, applied, (unsigned long long)plan.last_lsn,
		(long long)plan.last_time_us, (long long)b.time,
		plan.gap ? 1 : 0, (unsigned long long)plan.gap_expected, (unsigned long long)plan.gap_found,
		plan.stopped_by_until ? 1 : 0, plan.conflict ? 1 : 0, segs.size(), foreign, corrupt_names.size(),
		corrupt_beyond, complete ? 1 : 0);
	return complete ? 0 : 4;
}
// }}}

}	// namespace wal_archive
}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
